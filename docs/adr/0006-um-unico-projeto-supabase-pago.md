---
status: accepted
---

# Um único projeto Supabase pago

O GrillStudio usa Supabase local gratuito para desenvolvimento e testes e mantém exatamente um projeto Supabase pago na nuvem, usado primeiro no piloto controlado e depois como produção. A economia de um segundo projeto cloud é aceita em troca de não haver staging remoto depois do lançamento; o risco é compensado por testes locais completos, previews sem acesso ao remoto, migrations pequenas com backup, allowlists, modos sombra/assistido, feature flags e kill switch.
