"""Standard-library client for the Z15 molecular accelerator TCP service."""

import argparse
import socket
import struct
import time
from pathlib import Path


MAGIC = 0x5A
VERSION = 1
HEADER_BYTES = 16
PORT = 5001
MAX_PAYLOAD_BYTES = 24576

FLAG_RESPONSE = 0x01
FLAG_BUSY = 0x02
FLAG_ERROR = 0x04
FLAG_FALLBACK = 0x08

TASK_TANIMOTO = 0x00
TASK_GNN = 0x01
TASK_ADMET = 0x02
TASK_PIPELINE = 0x03
TASK_RELOAD = 0xFE

HEADER = struct.Struct("<BBBBIII")


class ClientError(Exception):
    pass


class ProtocolError(ClientError):
    pass


class ServerError(ClientError):
    def __init__(self, code, detail, busy=False, trace_id=None):
        super().__init__(
            "server error code={} detail={}{}".format(
                code, detail, " busy" if busy else ""
            )
        )
        self.code = code
        self.detail = detail
        self.busy = busy
        self.trace_id = trace_id


class Response:
    def __init__(self, task_id, flags, trace_id, batch_size, payload, seconds=0.0):
        self.task_id = task_id
        self.flags = flags
        self.trace_id = trace_id
        self.batch_size = batch_size
        self.payload = payload
        self.words = struct.unpack("<{}I".format(len(payload) // 4), payload)
        self.seconds = seconds


def payload_words(task_id, batch_size):
    if not 1 <= batch_size <= 64:
        raise ValueError("batch size must be in 1..64")
    if task_id == TASK_TANIMOTO:
        return 64 if batch_size == 1 else 32 + 32 * batch_size
    if task_id == TASK_GNN:
        if batch_size != 1:
            raise ValueError("GNN batch size must be 1")
        return 1679
    if task_id == TASK_ADMET:
        return 20 * batch_size
    if task_id == TASK_PIPELINE:
        if batch_size != 1:
            raise ValueError("Pipeline batch size must be 1")
        return 1763
    if task_id == TASK_RELOAD:
        if batch_size != 1:
            raise ValueError("reload batch size must be 1")
        return 4538
    raise ValueError("unknown task id")


def validate_payload(task_id, payload, batch_size):
    if len(payload) != payload_words(task_id, batch_size) * 4:
        raise ValueError(
            "payload length {} does not match task shape {}".format(
                len(payload), payload_words(task_id, batch_size) * 4
            )
        )


def pack_header(task_id, flags, payload_len, trace_id, batch_size):
    if not 0 <= task_id <= 0xFF or not 0 <= flags <= 0x0F:
        raise ValueError("header byte out of range")
    if not 0 <= payload_len <= MAX_PAYLOAD_BYTES:
        raise ValueError("payload length out of range")
    return HEADER.pack(
        MAGIC, VERSION, task_id, flags, payload_len, trace_id, batch_size
    )


def recv_exact(connection, size):
    chunks = bytearray()
    while len(chunks) < size:
        chunk = connection.recv(size - len(chunks))
        if not chunk:
            raise ProtocolError("connection closed during frame")
        chunks.extend(chunk)
    return bytes(chunks)


def receive_response(connection, expected_task, expected_trace, expected_batch):
    raw_header = recv_exact(connection, HEADER_BYTES)
    magic, version, task_id, flags, length, trace_id, batch_size = HEADER.unpack(
        raw_header
    )
    if magic != MAGIC or version != VERSION:
        raise ProtocolError("bad response magic or version")
    if not flags & FLAG_RESPONSE:
        raise ProtocolError("frame is not a response")
    allowed_flags = FLAG_RESPONSE | FLAG_BUSY | FLAG_ERROR | FLAG_FALLBACK
    if flags & ~allowed_flags or (flags & FLAG_BUSY and not flags & FLAG_ERROR):
        raise ProtocolError("invalid response flags")
    if task_id != expected_task:
        raise ProtocolError("response task mismatch")
    if expected_trace is not None and trace_id != expected_trace:
        raise ProtocolError("response trace mismatch")
    if batch_size != expected_batch:
        raise ProtocolError("response batch mismatch")
    if length > MAX_PAYLOAD_BYTES or length % 4:
        raise ProtocolError("invalid response payload length")
    payload = recv_exact(connection, length)
    if flags & FLAG_ERROR:
        if length != 8:
            raise ProtocolError("invalid server error payload")
        code, detail = struct.unpack("<II", payload)
        raise ServerError(code, detail, bool(flags & FLAG_BUSY), trace_id)
    return Response(task_id, flags, trace_id, batch_size, payload)


def send_request(connection, task_id, payload, batch_size, trace_id):
    validate_payload(task_id, payload, batch_size)
    connection.sendall(
        pack_header(task_id, 0, len(payload), trace_id, batch_size) + payload
    )


def request(host, task_id, payload, batch_size, trace_id, port=PORT,
            timeout=10.0, connection=None):
    validate_payload(task_id, payload, batch_size)
    owned = connection is None
    if owned:
        connection = socket.create_connection((host, port), timeout)
    start = time.perf_counter()
    try:
        connection.settimeout(timeout)
        send_request(connection, task_id, payload, batch_size, trace_id)
        response = receive_response(connection, task_id, trace_id, batch_size)
        response.seconds = time.perf_counter() - start
        return response
    finally:
        if owned:
            connection.close()


def _words(values):
    return struct.pack("<{}I".format(len(values)), *values)


def tanimoto_payload(query_word, target_word, batch_size=1):
    if batch_size == 1:
        return _words([query_word] * 32 + [target_word] * 32)
    return _words([query_word] * 32 + [target_word] * (32 * batch_size))


def gnn_payload():
    values = [0] * 1679
    values[0] = 1
    values[79] = 0x100
    return _words(values)


def admet_payload(batch_size=1):
    values = [0] * (20 * batch_size)
    for item in range(batch_size):
        values[item * 20] = 0x100
    return _words(values)


def pipeline_payload():
    return (
        tanimoto_payload(0xFFFFFFFF, 0xFFFFFFFF)
        + gnn_payload()
        + admet_payload()
    )


def _read_mem(path, expected_count):
    lines = path.read_text(encoding="ascii").splitlines()
    if len(lines) != expected_count:
        raise ValueError(
            "{} has {} values; expected {}".format(path, len(lines), expected_count)
        )
    values = []
    for line_number, line in enumerate(lines, 1):
        try:
            raw = int(line.strip(), 16)
        except ValueError as error:
            raise ValueError("{}:{} is not hexadecimal".format(path, line_number)) from error
        if not 0 <= raw <= 0xFFFF:
            raise ValueError("{}:{} is not signed 16-bit data".format(path, line_number))
        values.append(raw - 0x10000 if raw & 0x8000 else raw)
    return values


def pack_weights(output, data_dir=None):
    root = Path(__file__).resolve().parents[2]
    data_dir = Path(data_dir) if data_dir is not None else root / "test_data"
    values = _read_mem(data_dir / "gnn_weights_q8_8.mem", 8192)
    for model in range(4):
        prefix = data_dir / "admet_{}_".format(model)
        values.extend(_read_mem(Path(str(prefix) + "hidden_weights.mem"), 200))
        values.extend(_read_mem(Path(str(prefix) + "hidden_biases.mem"), 10))
        values.extend(_read_mem(Path(str(prefix) + "output_weights.mem"), 10))
        values.extend(_read_mem(Path(str(prefix) + "output_bias.mem"), 1))
    if len(values) != 9076:
        raise ValueError("packed weight count is not 9076")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(struct.pack("<{}h".format(len(values)), *values))
    if output.stat().st_size != 18152:
        raise ValueError("packed weight file is not 18152 bytes")
    return output


def _show(response):
    print(
        "trace={} status=OK words={} latency_ms={:.3f} results={}".format(
            response.trace_id,
            len(response.words),
            response.seconds * 1000.0,
            " ".join("0x{:08X}".format(word) for word in response.words),
        )
    )


def run_selftest(args):
    cases = (
        (TASK_TANIMOTO, tanimoto_payload(0xFFFFFFFF, 0xFFFFFFFF), (0x10000,)),
        (TASK_TANIMOTO, tanimoto_payload(0xAAAAAAAA, 0x55555555), (0,)),
        (TASK_TANIMOTO, tanimoto_payload(0xF0F0F0F0, 0xCCCCCCCC), (0x5555,)),
        (TASK_GNN, gnn_payload(), (0x100,)),
        (TASK_ADMET, admet_payload(), (187, 187, 187, 187)),
        (TASK_PIPELINE, pipeline_payload(), (187, 187, 187, 187)),
    )
    connection = socket.create_connection((args.host, args.port), args.timeout)
    try:
        connection.settimeout(args.timeout)
        for index, (task_id, payload, expected) in enumerate(cases, 1):
            response = request(
                args.host, task_id, payload, 1, index,
                args.port, args.timeout, connection
            )
            if response.words != expected:
                raise ProtocolError(
                    "selftest trace {} returned {}, expected {}".format(
                        index, response.words, expected
                    )
                )
            _show(response)
    finally:
        connection.close()
    print("ALL TCP SELF-TESTS PASSED")


def run_queue_test(args):
    connections = [
        socket.create_connection((args.host, args.port), args.timeout)
        for _ in range(5)
    ]
    try:
        for connection in connections:
            connection.settimeout(args.timeout)
        send_request(connections[0], TASK_GNN, gnn_payload(), 1, 7000)
        traces = list(range(7100, 7110))
        payload = admet_payload()
        frame = b"".join(
            pack_header(TASK_ADMET, 0, len(payload), trace, 1) + payload
            for trace in traces
        )
        connections[1].sendall(frame)
        receive_response(connections[0], TASK_GNN, 7000, 1)

        accepted = []
        busy = []
        for _ in traces:
            try:
                response = receive_response(
                    connections[1], TASK_ADMET, None, 1
                )
                accepted.append(response.trace_id)
            except ServerError as error:
                if not error.busy:
                    raise
                busy.append(error.trace_id)
        if accepted != traces[:8] or len(busy) < 1:
            raise ProtocolError(
                "queue result accepted={} busy={}".format(accepted, busy)
            )
        print("QUEUE TEST PASSED accepted={} busy={}".format(accepted, busy))
    finally:
        for connection in connections:
            connection.close()


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="192.168.1.10")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--timeout", type=float, default=10.0)
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("selftest").set_defaults(action=run_selftest)
    commands.add_parser("queue-test").set_defaults(action=run_queue_test)

    tanimoto = commands.add_parser("tanimoto")
    tanimoto.add_argument("query", type=lambda value: int(value, 0))
    tanimoto.add_argument("target", type=lambda value: int(value, 0))
    tanimoto.add_argument("--batch", type=int, default=1)

    commands.add_parser("gnn")
    admet = commands.add_parser("admet")
    admet.add_argument("--batch", type=int, default=1)
    commands.add_parser("pipeline")
    reload_command = commands.add_parser("reload")
    reload_command.add_argument("weights", type=Path)
    pack = commands.add_parser("pack-weights")
    pack.add_argument("--output", type=Path, required=True)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    try:
        if hasattr(args, "action"):
            args.action(args)
            return
        if args.command == "pack-weights":
            output = pack_weights(args.output)
            print("PACKED_WEIGHTS={} bytes={}".format(output, output.stat().st_size))
            return
        if args.command == "tanimoto":
            payload = tanimoto_payload(args.query, args.target, args.batch)
            task_id, batch_size = TASK_TANIMOTO, args.batch
        elif args.command == "gnn":
            payload, task_id, batch_size = gnn_payload(), TASK_GNN, 1
        elif args.command == "admet":
            payload, task_id, batch_size = (
                admet_payload(args.batch), TASK_ADMET, args.batch
            )
        elif args.command == "pipeline":
            payload, task_id, batch_size = pipeline_payload(), TASK_PIPELINE, 1
        else:
            payload = args.weights.read_bytes()
            task_id, batch_size = TASK_RELOAD, 1
        _show(request(
            args.host, task_id, payload, batch_size,
            int(time.time() * 1000) & 0xFFFFFFFF,
            args.port, args.timeout
        ))
    except (ClientError, OSError, ValueError) as error:
        parser.exit(1, "error: {}\n".format(error))


if __name__ == "__main__":
    main()
