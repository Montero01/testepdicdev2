# Revisão dos processos de desempenho — 17/11/2026

A versão foi atualizada no projeto Supabase conectado. Os registros de negócio existentes foram conferidos antes/depois e preservados. Não foram alteradas senhas, criados lançamentos fictícios na produção ou liberadas novas permissões operacionais.

## Cobertura do log

| Processo | Registro e consulta |
| --- | --- |
| PCP: cadastro e correção de analisado/salvo/pedidos | Antes/depois, autor, data, justificativa e revisão, como já instalado |
| PCP: registro/correção do desperdício | Antes/depois, supervisor/gerente responsável e justificativa |
| Caixa: cadastro e correção autorizada do fechamento | Antes/depois, valores, parcelas, autor, PDF e justificativa |
| PDF: reserva | Evento de reserva do arquivo no banco; não afirma que o envio já ocorreu |
| PDF: confirmação do envio | Evento autorizado que confere existência e metadados no Storage |
| PDF: falha de envio | Ocorrência informada pelo cliente, sem tratar um retorno de rede como prova de ausência do arquivo |
| PDF: associação ao fechamento | Evento automático de associação, gerado pelo banco |
| PDF: inclusão, troca ou retirada em correção | Evento automático com referência anterior/nova e motivo |
| PDF: download pela interface | Solicitação, acionamento e eventual falha informada pelo cliente |
| Dashboards PCP/Caixa e séries de indicadores | Consulta registrada no servidor, com usuário e filtros |
| CSV | Geração e acionamento, unidos também à linha do tempo geral do módulo |
| Autorizações por área | Concessão, alteração e revogação. Detalhes continuam exclusivos da Diretoria |
| Mudanças de cargo, setor, nível geral ou is_master | Evento de alteração dos campos que afetam o acesso ao desempenho; exclusivo da Diretoria |
| Configuração de módulos/áreas/visão da Diretoria | Eventos automáticos no banco; exclusivos da Diretoria |

A linha do tempo mantém pesquisa, meses anteriores por CSV, paginação e registro de exportações. A administração de áreas também oferece esse componente mensal, com escolha entre PCP e Caixa. Os eventos de acesso antigos são incluídos a partir do histórico existente, sem duplicar as alterações já registradas no novo fluxo.

As novas categorias de consultas e arquivos passam a ser registradas a partir desta atualização. Não foram inventados downloads, envios ou consultas anteriores. O sistema não prova que um arquivo foi efetivamente salvo no dispositivo. Requisições de Storage feitas fora do fluxo da interface também têm os registros próprios do serviço; o log funcional não é um substituto de todos os logs de infraestrutura.

## Correções encontradas

1. **Histórico do PCP e página do desperdício:** a lista diária usava os dados da página gerencial de desperdício para procurar cada valor. Em páginas diferentes, exibia “não informado” indevidamente. Agora busca pelo ID dos lançamentos exibidos, com RLS.
2. **Áreas decimais:** somas como 0,1 + 0,2 podiam superar 0,3 por erro de ponto flutuante no navegador. A comparação passou a usar milésimos inteiros.
3. **Menu durante operação:** era possível selecionar outra página enquanto o módulo ainda processava a anterior, deixando menu e conteúdo diferentes. A navegação aguarda a conclusão.
4. **Paginação do log:** uma pesquisa menor podia manter um número de página fora dos resultados. O componente ajusta e recarrega a página válida.
5. **Componente de log desmontado:** uma exportação pendente podia continuar alterando um componente que já tinha sido substituído. O controlador agora respeita o descarte.
6. **Viradas de mês e trimestre:** o filtro usava Manaus, mas o agrupamento mensal/trimestral de pontos podia usar UTC. Ambos agora usam a mesma data local.
7. **Percentuais do ranking na API:** participação e barra eram devolvidas como zero no resumo do PCP. Agora são calculadas sobre os totais, preservando a resposta usada por integrações anteriores.
8. **Texto do Caixa:** o sistema orientava procurar uma supervisão financeira que está desabilitada pela decisão atual de acesso. A orientação foi alinhada à configuração vigente. Nenhum novo poder de correção foi concedido.
9. **Confirmação de PDF após falha de rede:** o arquivo já enviado fica em cache enquanto a confirmação é repetida, sem novo upload desnecessário.
10. **Espaço dos controles do log:** campos e botões passam a duas colunas também na faixa intermediária com menu lateral.

## Permissões e integridade

Os responsáveis são obtidos da sessão no servidor. O cliente não escolhe o autor de um evento. O histórico não pode ser alterado ou excluído pela API do aplicativo. A pesquisa/CSV mantém o isolamento de Produção e Financeiro; supervisores e colaboradores não ganharam acesso ao log gerencial.

Alterações diretas por SQL sem usuário Auth são identificadas como operação administrativa e pela origem no banco. Não é atribuído um nome humano quando essa informação não existe. Campos de acesso anteriores que não tinham retrato de nome/e-mail usam o cadastro atual, mantendo o UUID original.

A coleta permanece com o colaborador e a correção autorizada com a supervisão. O registro de desperdício continua com supervisão/gerência de Produção. O Caixa permanece sem correção financeira pela interface enquanto não houver uma função autorizada, conforme a decisão anterior de gerência/Diretoria em consulta.

A migração aplicada é `20261117133433_performance_audit_all_flows_and_regression_fixes`. O SQL incluído é uma cópia de consulta, não deve ser executado novamente no projeto conectado.

## Verificações

- 40 testes SQL em banco local novo, com perfis, arquivos/metadados e registros fictícios: auditoria de processos, PDFs, consultas, autorização e isolamento.
- 24 testes SQL de regressão das metas e certificados.
- 83 verificações de interface e adaptador com API simulada, incluindo os erros de decimal, paginação independente, navegação em andamento, datas de mês/trimestre e chamadas de auditoria dos PDFs.
- 46 verificações de CSS, contraste e regras responsivas.
- Verificação com os perfis reais em transação revertida e comparação dos registros de PCP/Caixa antes/depois.
- Nenhum novo apontamento de segurança do Supabase em relação ao estado anterior; avisos legados permanecem fora desta alteração.

Não houve conferência visual em navegador autenticado nem envio/download de PDF real nesta execução. Os testes de Storage locais validam metadados, RLS e fluxo, sem simular o serviço físico. Esta revisão não é garantia de ausência de qualquer outro bug.
