# Logística CDE — módulo integrado

Disponível em **Desempenho → Logística**, preservando os temas claro/escuro, a navegação responsiva e o log mensal dos demais módulos.

## Seções

1. **Visão Geral:** indicadores de frota/equipe, movimentações, arrecadação, gastos, reposições, jornadas, manutenção realizada, manutenção prevista e abastecimentos. Sete gráficos: área por veículo, evolução diária, reposições por setor, saldo de jornada por colaborador, custo por tipo de manutenção, abastecimento por veículo e cronograma por data.
2. **Movimentações de carga:** dia, veículo, motorista, interna/externa, m², km, entrega com taxa, total arrecadado, total gasto, observações e ajustes com justificativa. São permitidas várias ocorrências por veículo/dia; a contagem é de movimentações registradas, não de destinos de entrega.
3. **Reposição:** dia, veículo, motorista, setor informado (Comercial, Produção, Transporte, Almoxarifado ou Outros), detalhe de Outros, observações, m², km e ajustes justificados. Não há integração automática com pedidos de outro sistema nesta etapa.
4. **Desempenho individual:** colaborador, entrada, saída para almoço, retorno, saída, saldo e observações. Um apontamento ativo por colaborador/dia. Jornadas que passam da meia-noite são identificadas. Sem intervalo é uma escolha explícita; não se deixa apenas um horário de almoço preenchido.
5. **Controle de manutenções:** veículo, tipo corretiva/preventiva, serviço, custo realizado, data de início, final opcional (em andamento), observações e ajustes.
6. **Cronograma de manutenção:** veículo, tipo, custo estimado, data prevista, serviço opcional e situação programada/concluída. Os filtros permitem consultar datas futuras; ao salvar fora do recorte, o painel passa para o dia do registro salvo.
7. **Histórico de abastecimento:** veículo, litros, custo, data, colaborador e observações.
8. **Log gerencial:** mesmo componente de pesquisa, meses anteriores por CSV, antes/depois e identificação de quem exportou.
9. **Cadastros:** colaboradores e veículos, exclusivos da gerência de Logística autorizada e da Diretoria.

## Como começar com dados reais

A Diretoria já tem acesso consolidado e aos cadastros. Nenhum motorista, veículo ou lançamento fictício foi cadastrado na produção.

1. Entre como Diretoria e abra **Logística → Cadastros**.
2. Cadastre os motoristas/ajudantes e a jornada diária prevista (padrão inicial de formulário: 08:00, alterável). O vínculo com um perfil existente do PDI é opcional. **Esse cadastro operacional não cria conta Auth, senha ou acesso ao PDI.**
3. Cadastre os veículos: nome, placa, modelo, marca opcional, ano/modelo opcional e aquisição opcional. Placas brasileiras antigas e Mercosul são aceitas e normalizadas. Inative em vez de excluir para preservar o histórico.
4. Em **Acessos por área**, selecione **Logística** e atribua a gerência/supervisão às pessoas responsáveis. Não foi dado acesso automaticamente a toda a Produção ou ao Financeiro.
5. O cargo protegido **Assistente de Logística**, já existente na base, está habilitado para os lançamentos. Cargos cujo `position` contém Logística seguem essa regra, desde que tenham nível operacional permitido. Cadastros de equipe/frota continuam bloqueados para colaboradores e supervisores.

## Permissões

| Acesso | Lançamentos | Ajustes/anulação | Dashboards | Cadastros | Log/CSV |
| --- | --- | --- | --- | --- | --- |
| Operação de Logística autorizada pelo cargo | Sim | Não | Orientação operacional; sem consolidado gerencial | Não | Não |
| Supervisão de Logística atribuída | Sim | Sim, com justificativa | Sim | Não | Não |
| Gerência de Logística atribuída | Não | Não | Sim | Sim | Sim |
| Diretoria/Master | Não | Não | Consolidado | Sim | Sim |
| Demais áreas sem autorização | Não | Não | Não | Não | Não |

São as permissões efetivas do banco. Alterar o HTML ou chamar a API diretamente não libera outra função. As atribuições por área não promovem o nível geral em `profiles`. Justificativas completas de ajustes ficam no log gerencial, não na projeção operacional das tabelas.

## Critérios de cálculo e histórico

- Quantidades e distâncias: até três casas decimais, sem separador de milhar no formulário. Valores monetários entram em centavos inteiros.
- Saldo das movimentações = arrecadado − gasto informado **nessas movimentações**. Combustível, manutenção e estimativas ficam separados, pois o “gasto informado” pode já conter despesas que aparecem nas outras seções. Não são somados em um custo geral que poderia duplicar valores.
- Sem taxa: arrecadado da movimentação deve ser zero. Com taxa, zero é permitido se nada tiver sido arrecadado naquele registro.
- Saldo da jornada = minutos trabalhados (intervalo descontado) − jornada prevista cadastrada. O valor previsto é guardado no apontamento. Mudar o cadastro depois não recalcula os dias anteriores. O previsto se aplica aos apontamentos, sem criar faltas automaticamente em dias sem registro. Não há calendário semanal/feriados nesta etapa.
- Horários em ordem podem atravessar a meia-noite uma vez, com duração total até 24 horas. O painel mostra quando termina no dia seguinte. Entrada/saída iguais representam duração zero, não uma jornada automática de 24 horas.
- Jornadas não são filtradas por veículo, pois não têm essa associação. Manutenção e cronograma não são filtrados por colaborador. Os filtros são aplicados onde existe o respectivo vínculo.
- Reposição tem indicadores próprios; não se calcula automaticamente uma taxa de erro sem conhecer a base total e possíveis duplicidades entre os processos.
- Custo por litro = soma dos custos / soma dos litros, ponderado pelos volumes. Não há km/l, pois o desenho não informa hodômetro ou consumo efetivo por tanque.
- Manutenção é filtrada pela data de início; cronograma pela data prevista. Alertas de serviços em andamento e programações vencidas são atuais e independentes do recorte, considerando o veículo selecionado. As estimativas não entram como gastos realizados.
- Anulações preservam o registro, revisão e justificativa. Registros anulados ficam fora dos indicadores; use **Incluir registros anulados** para consultá-los.
- Nomes/placas dos lançamentos são guardados como retrato histórico. Correções exigem a revisão ainda válida, evitando sobrescrever o ajuste de outra pessoa.

## Banco, auditoria e verificação

A migração `20261117154309_logistics_operations_fleet_staff_dashboards_and_audit` **já foi aplicada** no Supabase conectado. A cópia SQL no pacote é para consulta; não a execute novamente neste projeto. Ela depende das migrações anteriores do PDI.

Os cadastros, lançamentos, ajustes, anulações, consultas gerenciais, configurações e exportações são auditados. A pesquisa aceita diferenças de acentuação, por exemplo “reposição” e “reposicao”. Mudanças de autorização mantêm a restrição exclusiva da Diretoria. O navegador confirma geração/acionamento de CSV, não o salvamento final no dispositivo.

Verificação: 91 casos SQL em banco local criado do zero; 100 verificações de interface/adaptador com API simulada; 46 verificações CSS/contraste/regras responsivas. O fluxo de cadastro, lançamento, ajuste, dashboard e CSV foi verificado no Supabase real em transação revertida. Os registros existentes de PCP/Caixa, os 32 perfis, as metas e certificados foram preservados. Nenhum dado fictício foi deixado na produção.

A aparência no navegador e o uso com as contas reais dos colaboradores ainda precisam da conferência prática; esta execução não teve uma sessão de navegador autenticada.
