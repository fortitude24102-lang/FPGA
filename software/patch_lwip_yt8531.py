#!/usr/bin/env python3
"""Patch the generated Vitis 2019.2 lwIP PHY probe for generic Clause 22 PHYs."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


MARKER = "MOLRECOMMENDER_GENERIC_PHY_BEGIN"
OLD_FALLBACK = "RetStatus = get_Marvell_phy_speed(xemacpsp, phy_addr);"
NEW_FALLBACK = "RetStatus = get_Generic_phy_speed(xemacpsp, phy_addr);"
INSERT_BEFORE = "static u32_t get_IEEE_phy_speed(XEmacPs *xemacpsp, u32_t phy_addr)\n{"

PATCH_BLOCK = r"""/* MOLRECOMMENDER_GENERIC_PHY_BEGIN
 * YT8531C and other unknown RGMII PHYs must not use Marvell private-page
 * registers.  Negotiate and resolve speed using Clause 22 registers only.
 */
static u32_t get_Generic_phy_speed(XEmacPs *xemacpsp, u32_t phy_addr)
{
	u16_t control;
	u16_t status;
	u16_t partner;
	u32_t timeout_counter = 0;

	xil_printf("Start generic Clause 22 PHY autonegotiation\r\n");

	if (XEmacPs_PhyRead(xemacpsp, phy_addr,
			IEEE_AUTONEGO_ADVERTISE_REG, &control) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	control |= IEEE_ASYMMETRIC_PAUSE_MASK | IEEE_PAUSE_MASK;
	control |= ADVERTISE_100 | ADVERTISE_10;
	if (XEmacPs_PhyWrite(xemacpsp, phy_addr,
			IEEE_AUTONEGO_ADVERTISE_REG, control) != XST_SUCCESS) {
		return XST_FAILURE;
	}

	if (XEmacPs_PhyRead(xemacpsp, phy_addr,
			IEEE_1000_ADVERTISE_REG_OFFSET, &control) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	control |= ADVERTISE_1000;
	if (XEmacPs_PhyWrite(xemacpsp, phy_addr,
			IEEE_1000_ADVERTISE_REG_OFFSET, control) != XST_SUCCESS) {
		return XST_FAILURE;
	}

	if (XEmacPs_PhyRead(xemacpsp, phy_addr,
			IEEE_CONTROL_REG_OFFSET, &control) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	control |= IEEE_CTRL_AUTONEGOTIATE_ENABLE;
	control |= IEEE_STAT_AUTONEGOTIATE_RESTART;
	if (XEmacPs_PhyWrite(xemacpsp, phy_addr,
			IEEE_CONTROL_REG_OFFSET, control) != XST_SUCCESS) {
		return XST_FAILURE;
	}

	xil_printf("Waiting for PHY to complete autonegotiation.\r\n");
	do {
		/* IEEE status is latch-low, so read it twice. */
		if (XEmacPs_PhyRead(xemacpsp, phy_addr,
				IEEE_STATUS_REG_OFFSET, &status) != XST_SUCCESS ||
			XEmacPs_PhyRead(xemacpsp, phy_addr,
				IEEE_STATUS_REG_OFFSET, &status) != XST_SUCCESS) {
			return XST_FAILURE;
		}
		if ((status & IEEE_STAT_AUTONEGOTIATE_COMPLETE) != 0U) {
			break;
		}
		sleep(1);
		timeout_counter++;
	} while (timeout_counter < 30U);

	if ((status & IEEE_STAT_AUTONEGOTIATE_COMPLETE) == 0U) {
		xil_printf("Auto negotiation error \r\n");
		return XST_FAILURE;
	}

	if (XEmacPs_PhyRead(xemacpsp, phy_addr,
			IEEE_PARTNER_ABILITIES_3_REG_OFFSET, &partner) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	if ((partner & IEEE_AN3_ABILITY_MASK_1GBPS) != 0U) {
		return 1000U;
	}

	if (XEmacPs_PhyRead(xemacpsp, phy_addr,
			IEEE_PARTNER_ABILITIES_1_REG_OFFSET, &partner) != XST_SUCCESS) {
		return XST_FAILURE;
	}
	if ((partner & IEEE_AN1_ABILITY_MASK_100MBPS) != 0U) {
		return 100U;
	}
	if ((partner & IEEE_AN1_ABILITY_MASK_10MBPS) != 0U) {
		return 10U;
	}

	return XST_FAILURE;
}
/* MOLRECOMMENDER_GENERIC_PHY_END */

"""


def patch_source(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        if NEW_FALLBACK not in text:
            raise ValueError("unsupported lwIP source: incomplete existing patch")
        return False

    definition_index = text.rfind(INSERT_BEFORE)
    if definition_index < 0 or text.count(OLD_FALLBACK) != 1:
        raise ValueError("unsupported lwIP source: expected Vitis 2019.2 PHY fallback")

    text = text[:definition_index] + PATCH_BLOCK + text[definition_index:]
    text = text.replace(OLD_FALLBACK, NEW_FALLBACK, 1)
    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    try:
        changed = patch_source(args.source)
    except (OSError, UnicodeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print("PATCHED" if changed else "ALREADY_PATCHED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
