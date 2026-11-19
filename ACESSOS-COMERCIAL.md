# Autorizações específicas do Comercial

O acesso consolidado é concedido especificamente para o Comercial. Ter gestão em Logística, Estoque ou outro setor não concede acesso automático às vendas.

Consultores de Vendas mantêm acesso apenas aos próprios indicadores. A aplicação consulta a autorização do servidor para montar o menu; as políticas do banco e as funções de operação aplicam a mesma restrição às consultas, importações, ajustes, exclusões, exportações e logs.

A configuração efetiva das contas autorizadas e o histórico da alteração ficam no Supabase protegido. Este repositório público não contém a lista de identidades autorizadas.

Uma sessão aberta antes da atualização de permissões pode manter o item antigo no menu até recarregar a página. As novas consultas e operações já são validadas pelo servidor.

A correção foi verificada com testes de isolamento entre setores, restrição dos consultores aos próprios registros e bloqueio das funções de gestão para contas sem autorização comercial.
