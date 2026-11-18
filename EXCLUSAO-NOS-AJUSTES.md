# Exclusão dentro dos ajustes — 18/11/2026

O bloco/lista separado Gerenciar exclusões foi retirado de todas as páginas, inclusive Indicadores. Não é necessário consultar uma lista paralela para escolher o que excluir.

- PCP: Lançamentos do período > registro > Ajustes > Excluir lançamento. O desperdício vinculado também tem sua ação contextual. A gestão pode consultar os lançamentos sem ganhar permissão de coleta/edição da supervisão.
- Caixa: cada fechamento/comprovante do período possui Ajustes > Excluir lançamento. O envio de PDF e as permissões de edição financeira continuam inalterados.
- Logística: exclusão no ajuste do registro operacional. Pessoas e veículos exibem Excluir cadastro dentro do formulário Ajustar cadastro. Orçamento mensal próprio exibe a exclusão dentro do editor do orçamento; uma referência herdada não cria um registro fictício para excluir.
- Estoque: cada movimentação e sua conferência de desperdício possuem ajustes contextuais distintos. O desperdício é excluído pelo identificador da conferência, não pelo identificador do movimento. Jackson mantém a edição do desperdício; somente gestão pode excluir.

A ação exige confirmação e justificativa de 10 a 300 caracteres. Gerência e Diretoria mantêm a autorização já existente; supervisores/colaboradores continuam sem exclusão. A API de exclusão e suas validações no banco não foram alteradas. Permanecem exclusão lógica, cascata de desperdícios dependentes e auditoria com autor/motivo. Cancelar não envia alteração. A confirmação usa botão próprio, sem submeter os campos de edição ou criar formulários aninhados.

As permissões são consultadas uma vez por renderização e compartilhadas pelas ações dos registros, sem consulta separada de lista de exclusão. Após excluir, a lista e os indicadores são atualizados, a paginação volta à primeira página do recorte e os editores antigos são descartados. A implementação reutilizável é `CDEManagement.recordActions` para os próximos módulos.

Validação: 163 verificações de interface, 25 de arquivos, 22 de gráficos e 46 de CSS/contraste/responsividade. Verificados os identificadores/entidades enviados, ausência do bloco separado, confirmação e justificativa, ações em PCP/Caixa/Logística/Estoque/cadastros e preservação das permissões de supervisão e edição financeira. Testes de interface usam API simulada e não excluem registros reais. Nenhuma migração ou alteração de dados no Supabase nesta entrega. Sem inspeção visual em navegador real neste ambiente.
