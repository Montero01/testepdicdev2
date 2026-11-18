# Gestão e eficiência de desempenho — 18/11/2026

## Exclusão gerencial

Gerência (inclusive autorizações de área com nível manager) e Diretoria podem excluir informações de PCP, Caixa, Logística e Estoque. Colaboradores e supervisores não recebem exclusão. Em cada área existe Gerenciar exclusões; em Indicadores existe um controle consolidado com seleção de área/processo, inclusive para informações fora do dashboard operacional habitual. A lista gerencial mostra identificação resumida para selecionar o registro.

Excluir exige justificativa de 10 a 300 caracteres. O registro sai das listas, métricas e CSV operacionais, mas fica preservado para auditoria. Não há apagamento físico nem exclusão de logs. A exclusão do lançamento principal também exclui logicamente seu desperdício dependente (PCP e Estoque); excluir cadastro de pessoa/veículo preserva as movimentações históricas e seus snapshots. Ao excluir um PCP ou fechamento, fica liberado um novo registro ativo para o mesmo colaborador/data. Cada exclusão registra ator, data, motivo e estado anterior. PDFs históricos permanecem no armazenamento privado para rastreabilidade.

Padrão para novos módulos: registrar `deletion_targets` na configuração existente do módulo; usar `is_deleted`, política restritiva de leitura e a guarda compartilhada. A interface obtém os alvos pelo servidor. Não criar uma implementação de exclusão independente por aba. RPCs de exclusão usam autorização gerencial validada no banco e identificação de tabela/coluna por configuração protegida, sem aceitar SQL do cliente.

## Orçamento de abastecimento e entregas

Mês completo da frota inteira sob controle da Gabriele, conforme confirmado pelo Diretor. Novo painel expansível na Logística e em Indicadores para a gestão. Somente gerência/Diretoria definem/alteram o orçamento; ajuste exige justificativa. Não foi inventado orçamento histórico: sem valor cadastrado, orçamento/saldo/percentual aparecem ausentes.

- Gasto mensal: soma dos custos dos abastecimentos ativos, não excluídos, no mês escolhido, independentemente do colaborador.
- Saldo: orçamento menos gasto.
- Utilização: gasto/orçamento × 100. Orçamento zero deixa percentual indefinido; saldo negativo indica orçamento excedido.
- Entregas externas: somente movimentações ativas do tipo Externa, com quantidade, m² e km, detalhadas por veículo. Internas e Estoque não entram como entregas externas.

O indicador acompanha utilização de verba, não consumo km/l. Não é feita atribuição artificial de combustível exclusivamente às entregas externas, porque um abastecimento pode atender trajetos internos e externos. Budget e desperdício são tipos adicionais na mesma tabela de registros da Logística, sem novos bancos ou tabelas operacionais.

## Estoque

Vitor escolhe a data da movimentação, inicialmente o dia atual de Manaus. São permitidos dias passados; movimentação futura permanece inválida. O registro continua único na base compartilhada, identificado pelo autor e disponível à Logística. Tipo Interna e limitações operacionais anteriores preservados.

Dashboard: total m², quantidade de movimentações, dias com mais registros, evolução diária com tendência, composição da área conferida e dispersão quantidade × m² por dia. Quatro representações expansíveis. O Vitor acompanha esses indicadores dos seus registros; a gestão e o supervisor autorizado consultam conforme as permissões.

Só Jackson F. Maia registra/ajusta desperdício de Estoque, vinculado à movimentação. Deve informar m² e motivo/conferência (10 a 300 caracteres). Zero só é considerado após registro de conferência; ausência permanece pendente. O desperdício não pode superar a área movimentada, e uma correção de movimento não pode reduzir a área abaixo do desperdício já registrado.

Aproveitamento = (área movimentada conferida − desperdício informado)/área movimentada conferida × 100. O dashboard informa a quantidade de movimentos pendentes. Não se trata toda a produção não conferida como ausência de quebra. Excluir uma conferência volta a movimentação para pendente. A gerência pode excluir o registro auditado, mas não recebe permissão para inserir/editar o desperdício reservado ao Jackson.

## Interface

Ações compactas em desktop (36 px) e área de toque de pelo menos 44 px no celular; campos comuns com altura mínima de 40 px. Botão de registro do Estoque ocupa só o espaço necessário, fora das células elásticas da grade. CSV fica em um controle discreto expansível; a legenda extensa foi removida. Temas claro/escuro mantidos.

## Validação e migrações

Migrações aplicadas: 20261118153741 e 20261118153906. Nenhuma tabela ou banco adicional: 40 tabelas públicas mantidas. Antes/depois: 29 movimentações físicas preservadas; hashes dos campos preexistentes de PCP, Caixa e Logística idênticos. Nenhum dado de negócio real foi excluído nos testes, nem foram criados orçamentos ou desperdícios fictícios em produção.

Testes: 142 verificações de interface, 25 de arquivos, 22 de gráficos e 46 de CSS/contraste/responsividade. Dois roteiros SQL locais em transações revertidas verificaram data retroativa, autoria, escopos, orçamento/percentual/saldo, exclusão de internas das entregas externas, limites de desperdício, pendências, exclusão em cascata, log e novo lançamento diário após exclusão. Migração completa também instalada em uma base local independente. Permissões e dashboards de usuários reais consultados com rollback. Avisos legados do Supabase permanecem iguais aos documentados em DASHBOARDS.md. Sem inspeção visual em navegador real neste ambiente.
