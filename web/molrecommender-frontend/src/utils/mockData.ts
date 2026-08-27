export const skillDimensions = [
  '化学信息学',
  '靶点生物学',
  'ADMET预测',
  '分子对接',
  'GNN/机器学习',
  '合成可及性',
]

export const demoCandidates = [
  {
    id: 'mol-egfr-001',
    smiles: 'COc1ccc2ncnc(Nc3ccc(F)c(Cl)c3)c2c1',
    pKi: 8.6,
    logP: 3.8,
    molecularWeight: 393.8,
    selectivity: '> 12x',
    status: '通过',
    note: '活性与成药性较均衡，可作为首轮候选。',
  },
  {
    id: 'mol-egfr-002',
    smiles: 'CCOc1cc2ncnc(Nc3cccc(Br)c3)c2cc1OCC',
    pKi: 8.2,
    logP: 5.4,
    molecularWeight: 452.3,
    selectivity: '> 10x',
    status: '需优化',
    note: '活性达标但 logP 偏高，建议降低疏水性。',
  },
  {
    id: 'mol-egfr-003',
    smiles: 'CN1CCN(c2ccc(Nc3ncnc4ccccc34)cc2)CC1',
    pKi: 7.9,
    logP: 3.1,
    molecularWeight: 371.5,
    selectivity: '> 8x',
    status: '风险',
    note: '活性略低，可作为结构优化参考。',
  },
]

export const resources = [
  {
    id: 'res-lecture-logp',
    type: '图文讲义',
    title: 'logP、极性表面积与口服吸收的关系',
    blindSpot: 'ADMET预测',
    difficulty: 72,
    match: 96,
    summary: '帮助理解疏水性、溶解度和吸收之间的取舍。',
  },
  {
    id: 'res-guide-docking',
    type: '实操指南',
    title: 'EGFR 小分子对接流程与结果解读',
    blindSpot: '分子对接',
    difficulty: 64,
    match: 91,
    summary: '从蛋白准备、口袋选择到打分结果复核的完整操作指南。',
  },
  {
    id: 'res-practice-synthesis',
    type: '测试练习',
    title: '候选分子的合成可及性快速判断',
    blindSpot: '合成可及性',
    difficulty: 58,
    match: 88,
    summary: '通过结构片段识别高风险合成路径。',
  },
]
