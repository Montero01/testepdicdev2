# Visual aprovado integrado ao testepdicdev2

Integração de 20/11/2026 sobre o commit `28055b59ed0b8ea69765456fc96a1405a41f2f3f`.

O menu aprovado no laboratório foi aplicado à aplicação real: lateral esquerda de 270 px, cabeçalho com marca e linha laranja, navegação com rolagem própria, avatar/setor/cargo e controles no rodapé. Tema claro com menu azul; tema escuro com menu preto. Preferência existente preservada; sem preferência salva, inicia claro. Em até 960 px, Menu/Fechar compartilham o mesmo controle flutuante de 132 × 56 px com borda degradê de 3 px, controle de foco, Escape, sobreposição e bloqueio do conteúdo atrás.

Navegação: Meu PDI, Meus Certificados, Academy, Indicadores do PDI, Gerenciar Metas, Cadastro; separador Performance; Desempenho e Indicadores de performance. Itens gerenciais respeitam o perfil e as autorizações existentes. Todos podem abrir seu próprio Meu PDI. Supervisão não recebe Gerenciar Metas. Cadastro organiza a consulta autorizada de colaboradores, a gestão de acessos existente da Diretoria e o acesso aos cadastros de Logística. Ranking continua disponível nos indicadores do PDI; o avatar abre o perfil, que conserva foto e senha reais.

Desempenho exibe cartões para os módulos efetivamente autorizados pelo servidor. PCP, Caixa, Logística, Estoque e Comercial continuam usando o mesmo cliente Supabase autenticado e suas validações, RLS, RPCs, upload, importação XLS e auditoria. Nenhum adaptador fictício ou modo de consulta do laboratório foi copiado. `dados-reais.js` e os módulos de PCP, Caixa, Estoque e Comercial permanecem intactos. Nenhuma tabela, política, função SQL, conta ou dado de negócio foi alterado para essa publicação.

A Logística recebeu as abas, cronograma dentro de Manutenções, atalhos de período, oito cartões principais, sombras suaves, painel mensal acima dos gráficos, cartões de saldo/veículos, três comparativos adicionais e os controles sem borda aprovados. Os formulários de lançamento/cadastro foram preservados. O X de exclusão continua dentro do ajuste e exige confirmação/justificativa, com a mesma RPC e permissão de gestão. Exportações reais continuam auditadas; controles de CSV ficam discretos.

Os indicadores complementares leem a matriz existente `pdi_logistics_records`, pelo cliente autenticado, sem gravações adicionais. Distância soma movimentações e reposições; entregas contam lançamentos de movimentações externas; agrupamento mensal distingue o ano. Custo/km compara abastecimentos e km do mesmo veículo no mês completo da referência; não mede consumo por tanque. Sem km ou abastecimento, não inventa índice. Manutenção prevista considera cronogramas programados. A consulta original de dashboard e seu log são mantidos.

## Validação

- `node testes/visual-integrado.mjs`: regressões de produção e menu/rotas/autorização.
- `python testes/visual-estilos.py`: cascata dos temas, 270 px, Menu/Fechar, controles de todos os módulos, seletor e exportações em diferentes resoluções.
- `node testes/logistica-projecoes.mjs`: filtros e cálculos complementares, com transporte SELECT simulado.
- Testes existentes do Comercial: cálculos, metas, Master, integração, importação, pendências e XLS.

Testes DOM/CSS com API simulada; não substituem inspeção visual ou login com contas reais no navegador. Não foram gravados dados fictícios no Supabase.

## Retorno à versão anterior

O commit-base acima identifica a versão completa anterior. A atualização é publicada em um único commit, permitindo reverter esse commit pela interface do GitHub se necessário. A cópia ZIP da versão anterior foi entregue separadamente. Não reexecute os SQLs existentes: esta atualização é de frontend.
