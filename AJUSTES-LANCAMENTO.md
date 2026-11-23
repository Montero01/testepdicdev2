# Revisão de textos para o lançamento — 23/11/2026

| Local | Texto anterior | Ajuste e motivo |
|---|---|---|
| PDI · login | PDI CDE · Acesso real | Acesso à plataforma. “Real” distinguia uma versão de demonstração. |
| PDI · login | Conectado ao Supabase da CDE. As alterações são reais. | Removido. Citava infraestrutura e dava impressão de aviso de desenvolvimento antes da autenticação. |
| PDI · rodapé do login | Baixar os arquivos | Removido o link ZIP do repositório. Distribuição do código não faz parte da navegação do colaborador. O repositório e seus arquivos permanecem disponíveis à equipe técnica. |
| PDI · confirmação de exclusão | Essa exclusão afeta os dados reais. | Retirada só essa frase redundante. Mantido o alerta de que a meta e seus comprovantes serão removidos. |
| PDI · Indicadores | Dados reais para apoiar o acompanhamento da equipe. | “Acompanhe os indicadores e a evolução da equipe.” Foco na finalidade da página. |
| PDI · administração de áreas | No Financeiro, nesta etapa, somente gerência. | “No Financeiro, o acesso é restrito à gerência.” Descreve a regra atual sem tom de implementação provisória. |
| Academy · acesso | Sua sessão será compartilhada automaticamente. | Removida a promessa automática; o compartilhamento depende da sessão e da origem usada. A orientação para entrar pelo PDI foi mantida. |
| Academy · redirecionamentos | Endereço do PDI antigo | Login/saída apontam para o mesmo testepdicdev2 do botão Voltar ao PDI. |
| Academy · caixa vazia | Nenhuma notificação ainda. | “Nenhuma notificação no momento.” Correto também quando os avisos lidos já expiraram. |

Foram mantidos os exemplos de preenchimento, prévia de cursos dos administradores, regras da campanha, explicações de cálculo, restrições de acesso, confirmações de exclusão e justificativas. Essas mensagens apoiam tarefas reais; não são sobras de um protótipo. Comentários do código e documentação técnica também não foram removidos, pois não aparecem na interface do colaborador.

O comportamento de notificações foi atualizado no Academy: validade individual de 24 horas após a primeira abertura, sem remover avisos dos usuários que ainda não leram. Os testes do banco foram revertidos; nenhum dado fictício permaneceu.
