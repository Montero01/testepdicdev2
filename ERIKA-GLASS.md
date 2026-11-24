# Erika Glass

O módulo usa o mesmo Supabase do PDI. Não cria outra base nem replica tabelas dos demais setores. Empresas e produtos são compartilhados entre vendas, produção, financeiro e Estoque E.G.; os lançamentos operacionais ficam em uma matriz `pdi_eg_records`, com razão de estoque e auditoria próprios.

O acesso principal é **Desempenho → Erika Glass**. Dentro dele, os botões **Desempenho** e **Estoque** organizam os processos autorizados. Não há dois cartões separados de E.G. no menu de desempenho.

## Acessos

- Adriane Pinheiro Campos: coordenação, catálogo/importação, empresas, vendas, visitas, conferência, preparo e financeiro.
- Jackson F. Maia: entradas e saídas no Estoque E.G. e tratamento de ocorrências; sem financeiro ou exclusão gerencial.
- Gerência, Diretoria e Master: visão e operações gerenciais. Anulação preserva histórico e exige justificativa.
- Cargos futuros no Profile: Vendas E.G., Promotoria E.G. e Produção E.G. Os nomes também aceitam a forma Erika Glass. O vendedor/promotor consulta seus registros; a produção consulta transferências e preparo. Custos e financeiro ficam restritos à coordenação e gestão.
- Vitor não recebe acesso ao Estoque E.G.

As duas atribuições iniciais são explícitas em `pdi_eg_access`. Não foram alterados cargos nem saldos de perfis existentes. Não há produtos, empresas ou estoques de exemplo na base publicada.

## Rotina

1. A coordenação cadastra empresas e produtos (ou importa catálogo XLS/XLSX), e define a composição de kits.
2. Jackson/gestão registra entradas novas no almoxarifado e envia transferências.
3. Adriane/Produção confere os itens e confirma recebimento; só então há saldo bruto no destino.
4. O preparo consome itens brutos ou componentes do kit e gera produtos acabados.
5. O pedido só fecha com saldo acabado disponível e gera parcelas previstas. O fechamento compromete as unidades e as retira do saldo disponível; a entrega confirma a saída sem repetir a baixa. Anular o pedido reverte seu compromisso de estoque. Almoxarifado, transferências em trânsito e bruto não podem ser comercializados.
6. No Financeiro, cada parcela recebe baixa manual com data e valor efetivos. Parcelas podem receber baixas parciais, sem ultrapassar seu saldo.

Estoque começa em zero. Saldos negativos, conferência repetida e estornos que dependem de produtos já consumidos são bloqueados em transação. Para desfazer uma cadeia, anule primeiro as operações dependentes. A chave de requisição evita repetir a mesma operação após reenvio de rede.

## Indicadores

- Valor vendido: soma dos pedidos ativos do recorte; ticket médio: valor vendido / quantidade de pedidos.
- Quantidade e valor orçados vêm dos relatórios diários. O valor orçado salvo no pedido não é somado novamente.
- Conversão de volumes: pedidos / orçamentos × 100. É uma relação agregada, sem rastreamento individual do orçamento até seu fechamento.
- Visitas informadas nos relatórios e visitas agendadas/realizadas pela promotoria são apresentadas separadamente para evitar dupla contagem.
- Previsões usam vencimentos; baixas usam datas efetivas; estoque por estágio é a posição atual, não um saldo retroativo.
- Preços de custo ausentes continuam ausentes. Não são presumidos como zero nem usados para declarar lucro.

## Fotos e auditoria

No formulário Registrar/Ajustar visita, as seções Fotos antes e Fotos depois oferecem Tirar foto (câmera traseira quando suportada pelo navegador) e Anexar da galeria. Até três imagens antes e três depois por visita, JPG/PNG/WebP até 5 MB cada. As imagens têm prévia local e são enviadas depois de salvar a visita; em falha parcial, Salvar retoma os anexos sem recriar o registro. O botão Fotos antes / depois continua disponível para visitas já registradas. Bucket privado, com acesso pela visita e links temporários. A retirada de uma foto é auditada; se a limpeza física não for autorizada pelo Storage, o arquivo permanece privado sem vínculo ativo. Não foi ampliado o acesso a arquivos órfãos.

Log contém usuário, cargo, horário, antes/depois e justificativa. Exportações CSV registram quem iniciou a geração. O total de linhas informado pelo cliente no evento de exportação não é prova de download concluído.

## Implantação e testes

`sql/erika_glass.sql` documenta a sequência das migrações aplicadas no Supabase (não é script para reaplicar sobre uma instalação existente). As operações usam RPCs autenticadas, RLS e funções privadas com validações no servidor; nenhuma chave administrativa fica no navegador.

Testes transacionais em `testes/erika-glass-backend.sql` terminam em ROLLBACK. Testes de interface e de gráficos usam DOM simulado; não substituem um teste visual em navegador real com uma conta autorizada.

A revisão de segurança não apontou novas funções públicas privilegiadas no E.G. O aviso informativo de RLS sem policy em `pdi_eg_requests` é intencional: a tabela é interna, não tem privilégios de cliente e só é acessada pelo comando privado. Referência: https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy . Os avisos anteriores de funções antigas do PDI e proteção de senhas não foram alterados nesta implantação.
