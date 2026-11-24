# Gestão de acessos do Desempenho

Disponível para Diretoria/Master em **Desempenho → Gerenciar acessos** e **Cadastro → Gerenciar acessos**. As rotas, a consulta administrativa e a gravação validam a autorização no servidor.

## Operação

1. Pesquise o colaborador por nome, cargo ou setor.
2. Escolha PCP, Caixa, Logística, Estoque, Comercial Vendas ou Erika Glass.
3. Selecione a permissão e clique em Adicionar ao resumo.
4. Confira as mudanças, informe a justificativa e salve.

Bloquear impede o acesso ao módulo, inclusive para contas que o recebiam pelo cargo. Restaurar padrão remove o efeito da exceção e volta às regras anteriores; pode restabelecer um acesso herdado. Cada módulo apresenta somente os perfis que suporta. Diretoria/Master mantém visão consolidada protegida.

As permissões de cargo existentes não foram migradas nem substituídas por concessões novas. A matriz de exceções foi implantada vazia. A comparação de contexto dos 34 perfis antes e depois da implantação não encontrou diferenças. Nenhum cargo, vínculo por área, autorização E.G. ou dado operacional foi alterado pela implantação.

## Limites e auditoria

A coleta própria de PCP/Caixa pode ser autorizada individualmente sem mudar o campo position do colaborador. Ela continua restrita ao próprio lançamento diário, com as validações de dados existentes. A supervisão PCP continua exclusiva de Rodrigo F. L. Campos; o desperdício do Estoque permanece exclusivo de Jackson.

Permissões deste módulo não promovem o colaborador globalmente: por exemplo, Gestão Comercial não dá gestão sobre outros setores. Gestão e cadastros da Logística não concedem exclusão gerencial a quem não possui o cargo requerido. As permissões E.G. distinguem vendas, promotoria, produção, estoque, coordenação e gestão completa. A exclusão no E.G. continua exigindo cargo gerencial.

Alterações registram ator, horário, módulo, colaborador, antes/depois e justificativa no histórico de acessos. Uma revisão por colaborador/módulo impede sobrescrever uma mudança concorrente. Restaurar padrão conserva a revisão e o histórico. Em alterações múltiplas, resultados parciais são mostrados; sucessos não são reenviados. Os logs mensais dos processos já existentes continuam disponíveis na página.

O bloqueio é consultado no banco em novas consultas e operações, sem depender de novos claims de JWT. Menus em sessões já abertas são atualizados ao recarregar. Arquivos ou dados já recebidos pelo navegador não são apagados remotamente, e links temporários já emitidos mantêm seu prazo original de expiração.

## Implementação e validação

A tabela `pdi_performance_access` tem RLS e somente leitura pelo cliente, limitada ao próprio perfil ou à administração. A escrita passa por uma função privada que exige Diretoria/Master e valida o módulo/perfil/justificativa/revisão. As funções públicas são invoker; nenhuma chave administrativa foi adicionada ao frontend. Políticas restritivas e guardas nos RPCs cobrem os bloqueios e o modo consulta. As implementações anteriores foram preservadas em schema privado para resolução do padrão.

Os SQLs `gestao_acessos_desempenho.sql`, `gestao_acessos_endpoints.sql` e `gestao_acessos_coleta.sql` documentam as migrações aplicadas após autorização explícita da Diretoria; não devem ser reaplicados em uma instalação existente.

Passaram testes reais com role authenticated e ROLLBACK: administração negada para funcionário, proteção de Diretoria/Master, concessão e lançamento próprio PCP/Caixa, bloqueio de leitura própria via RLS/RPC, consulta sem escrita, restauração do padrão, concorrência, escopos de Comercial/E.G./Estoque/Logística e auditoria. Os dados e autorizações temporários dos testes foram revertidos. Passaram ainda 19 testes de DOM/RPC do componente, 170 de interface e 324 de integração visual. Não houve login ou teste de pixels em navegador real.

A revisão de segurança manteve somente os avisos anteriores do projeto, sem novo alerta para este módulo. Referências do linter: https://supabase.com/docs/guides/database/database-linter .
