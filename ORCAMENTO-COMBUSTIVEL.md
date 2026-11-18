# Orçamento de combustível — continuidade e apresentação

Atualização de 18/11/2026. A Visão Geral da Logística substitui o contador Outros usuários de veículos por Orçamento de Combustível utilizado: valor abastecido, percentual do orçamento e referência mensal. O KPI considera a frota inteira e o mês completo da data final do filtro, identificado no próprio cartão; os demais indicadores continuam com seus filtros anteriores. A seleção de mês no painel detalhado também atualiza a referência do cartão.

O painel Abastecimento mensal e entregas externas agora fica dentro de Detalhamentos por indicador. Para acessos limitados aos cadastros, fica ao final dos cadastros. Não aparece antes dos indicadores principais. Edição do orçamento continua exclusiva da gerência e Diretoria, com auditoria anterior preservada.

## Continuidade confirmada pelo Diretor

O orçamento é repetido nos meses seguintes sem somar saldo anterior. A definição ativa mais recente, no mês consultado ou anterior, serve como orçamento efetivo. Um mês sem definição própria usa a referência herdada, inclusive após lacunas de meses. Uma nova definição mensal passa a ser a referência dos meses seguintes. Orçamento zero também é uma definição válida e interrompe a herança do valor anterior. Uma definição futura nunca altera um mês passado.

Não são criadas cópias de orçamento para cada mês. O cálculo usa a mesma tabela existente de registros de Logística. O painel identifica mês de origem quando houver herança. Ao definir valor próprio para o mês, a gestão cria o registro mensal auditado pelo fluxo já existente. Alterações/exclusões de definições anteriores repercutem nos meses que ainda dependem delas; definições próprias posteriores permanecem respeitadas.

## Indicadores de gestão financeira

- Utilização = abastecimentos do mês / orçamento efetivo × 100.
- Saldo = orçamento efetivo − abastecimentos do mês, sem sobra de meses anteriores.
- Saldo percentual = saldo / orçamento × 100.
- Gasto diário médio = gasto / dias do mês já transcorridos, incluindo o dia atual.
- Projeção de gasto = gasto × dias totais do mês / dias transcorridos.
- Saldo projetado = orçamento − projeção de gasto.

Mês encerrado usa todos os dias: projeção coincide com o gasto efetivo. Mês futuro não tem projeção, pois não possui dias transcorridos. Orçamento ausente ou zero não produz percentual artificial; quando ausente, saldo também fica indefinido. A situação de gestão indica se o ritmo financeiro projeta ultrapassar a verba. Valores monetários exibidos com centavos inteiros, sem perda por conversão para ponto flutuante.

Essas métricas descrevem eficiência financeira e gestão da verba. Não são eficiência mecânica km/l: o sistema ainda não tem hodômetro por abastecimento nem atribuição confiável de combustível a cada viagem. Entregas externas por veículo permanecem separadas e não recebem rateio fictício dos gastos de viagens internas.

## Verificação

Migração 20261118155813 aplicada: somente substituição da função de consulta mensal. Nenhuma tabela, banco ou registro de negócio adicional. Os 31 registros de Logística e seu hash permaneceram iguais antes/depois. Consulta com o acesso real da Gabriele validou os novos campos sem escrever dados.

147 verificações de interface, 25 de arquivos, 22 de gráficos, 46 de CSS/contraste/responsividade. SQL local com rollback cobriu herança entre meses, lacunas, ausência de orçamento passado, nova referência gerencial, zero explícito, mês futuro e mês encerrado. Avisos legados do Supabase permanecem iguais. Sem inspeção visual em navegador real neste ambiente.
