// @vitest-environment jsdom
import { config, flushPromises, shallowMount } from '@vue/test-utils'
import { beforeAll, describe, expect, it, vi } from 'vitest'

import MoleculeView from './MoleculeView.vue'
import { getFingerprint, getMoleculeInfo, getSimilarity } from '../utils/api'

vi.mock('../utils/api', () => ({
  getFingerprint: vi.fn(),
  getMoleculeInfo: vi.fn(),
  getSimilarity: vi.fn(),
}))

describe('MoleculeView FPGA source', () => {
  beforeAll(() => {
    config.global.renderStubDefaultSlot = true
  })

  it('shows the source returned by hardware similarity instead of a fixed fallback', async () => {
    vi.mocked(getMoleculeInfo).mockResolvedValue({ status: 'success', data: {} } as never)
    vi.mocked(getFingerprint).mockResolvedValue({
      status: 'success', source: 'cpu_fallback', trace_id: 'fingerprint-trace', data: {},
    } as never)
    vi.mocked(getSimilarity).mockResolvedValue({
      status: 'success', source: 'fpga',
      data: { similarity: 0.625, accelerated: true, trace_id: 'fpga-trace' },
    } as never)

    const wrapper = shallowMount(MoleculeView, {
      global: {
        stubs: {
          ElCard: { template: '<section><slot name="header"/><slot/></section>' },
          ElTable: { template: '<div />' },
          ElTableColumn: true,
          ElInput: true,
          ElButton: true,
          ElProgress: true,
          HallucinationBadge: true,
          FpgaCompute: {
            props: ['source', 'traceId'],
            template: '<output data-testid="fpga-source">{{ source }}|{{ traceId }}</output>',
          },
        },
      },
    })

    await (wrapper.vm as unknown as { queryMolecule: () => Promise<void> }).queryMolecule()
    await (wrapper.vm as unknown as { compare: () => Promise<void> }).compare()
    await flushPromises()

    expect(wrapper.get('[data-testid="fpga-source"]').text()).toBe('fpga|fpga-trace')
    expect(wrapper.text()).toContain('相似度 63%')
  })
})
