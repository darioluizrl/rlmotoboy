/* MegaEntregas · modo DEMONSTRAÇÃO: banco simulado no navegador (nada vai para o banco real) */
/* Supabase simulado para teste de interface (estado salvo no localStorage do navegador de teste) */
(function(){
  const K="__demodb"; const DU=window.DEMO_U||null;
  const load=()=>{ const db=JSON.parse(localStorage.getItem(K)||"null")||{session:null,users:[],membros:[],perfis:[],documentos:[],convites:[],docs:[],storage:{}};
    if(DU){ const u=db.users.find(x=>x.id===DU); db.session=u?{user:u}:null; } return db; };
  const save=db=>localStorage.setItem(K,JSON.stringify(db));
  const err=m=>({data:null,error:{message:m}});
  const uid=()=>"u-"+Math.random().toString(36).slice(2,10);
  function me(db){ return db.session&&db.session.user; }
  function isAdmin(db){ const u=me(db); return !!u && db.membros.some(m=>m.user_id===u.id&&m.ativo&&["admin","dono"].includes(m.papel)); }
  function isDono(db){ const u=me(db); return !!u && db.membros.some(m=>m.user_id===u.id&&m.ativo&&m.papel==="dono"); }
  function rlsSelect(db,t,rows){
    const u=me(db); if(!u) return [];
    if(t==="docs") return db.membros.some(m=>m.user_id===u.id&&m.ativo&&["dono","admin","funcionario","orcamento"].includes(m.papel))?rows:[];
    if(t==="convites") return isAdmin(db)?rows:[];
    if(["perfis","documentos","membros"].includes(t)) return rows.filter(r=>r.user_id===u.id||isAdmin(db));
    if(t==="candidaturas") return rows.filter(r=>r.prestador_id===u.id||isAdmin(db)||(db.servicos||[]).some(s=>s.id===r.servico_id&&s.criado_por===u.id));
    if(t==="servicos") return rows.filter(r=>r.criado_por===u.id||r.pego_por===u.id||isAdmin(db));
    if(t==="config_sistema") return db.membros.some(m=>m.user_id===u.id&&m.ativo)?rows:[];
    return rows;
  }
  function Q(t){ this.t=t; this.f=[]; this.op="select"; this.single=false; this.ord=null; }
  Q.prototype.select=function(){ return this; };
  Q.prototype.eq=function(c,v){ this.f.push(r=>r[c]===v); return this; };
  Q.prototype.in=function(c,v){ this.f.push(r=>v.includes(r[c])); return this; };
  Q.prototype.order=function(c,o){ this.ord=[c,(o&&o.ascending===false)?-1:1]; return this; };
  Q.prototype.range=function(){ return this; };
  Q.prototype.maybeSingle=function(){ this.single=true; return this; };
  Q.prototype.insert=function(v){ this.op="insert"; this.v=v; return this; };
  Q.prototype.update=function(v){ this.op="update"; this.v=v; return this; };
  Q.prototype.delete=function(){ this.op="delete"; return this; };
  Q.prototype.then=function(res,rej){ return Promise.resolve(this.run()).then(res,rej); };
  Q.prototype.run=function(){
    const db=load(); const tab=db[this.t]=db[this.t]||[]; const u=me(db);
    if(this.op==="select"){ let rows=rlsSelect(db,this.t,tab).filter(r=>this.f.every(f=>f(r)));
      if(this.ord){ const [c,d]=this.ord; rows.sort((a,b)=>(a[c]>b[c]?1:-1)*d); }
      return {data:this.single?(rows[0]||null):rows,error:null}; }
    if(this.op==="insert"){
      const rows=(Array.isArray(this.v)?this.v:[this.v]).map(x=>({...x}));
      if(this.t==="convites"){ if(!isAdmin(db)) return err("new row violates row-level security policy"); rows.forEach(r=>{r.usos=0;r.ativo=true;r.criado_em=new Date().toISOString();}); }
      if(this.t==="documentos"){ const p=db.perfis.find(p=>p.user_id===u.id); if(!p||!["pendente","recusado"].includes(p.status)) return err("new row violates row-level security policy for table \"documentos\"");
        rows.forEach(r=>{ r.id=uid(); r.user_id=u.id; r.criado_em=new Date().toISOString(); if(!r.caminho.startsWith(u.id+"/")) throw new Error("rls"); }); }
      tab.push(...rows); save(db); return {data:null,error:null}; }
    const alvo=rlsSelect(db,this.t,tab).filter(r=>this.f.every(f=>f(r)));
    if(this.op==="update"){ if(this.t==="convites"&&!isAdmin(db)) return {data:null,error:null}; alvo.forEach(r=>Object.assign(r,this.v)); save(db); return {data:null,error:null}; }
    if(this.op==="delete"){ db[this.t]=tab.filter(r=>!alvo.includes(r)); save(db); return {data:null,error:null}; }
  };
  const rpcs={
    primeiro_admin(db){ return null; },
    verificar_convite(db,a){ const c=db.convites.find(c=>c.codigo===String(a.p_codigo||"").trim().toUpperCase()); return c&&c.ativo&&c.usos<c.usos_max&&(!c.expira_em||new Date(c.expira_em)>new Date())?c.tipo:null; },
    registrar_cadastro(db,a){ const u=me(db); if(!u) throw "Entre com sua conta primeiro";
      const c=db.convites.find(c=>c.codigo===String(a.p_convite||"").trim().toUpperCase());
      if(!c||!c.ativo||c.usos>=c.usos_max) throw "Convite inválido, vencido ou já usado";
      if(db.perfis.some(p=>p.user_id===u.id)) throw "Você já tem um cadastro";
      const d=a.p_dados; if(db.perfis.some(p=>p.documento===d.documento)) throw "Já existe um cadastro com este CPF/CNPJ. Fale com a RL.";
      const now=new Date().toISOString();
      const env=d.envia!=null?d.envia:c.tipo==="contratante", rec=d.recebe!=null?d.recebe:c.tipo==="prestador";
      if(!env&&!rec) throw "Marque se você envia serviços, recebe serviços ou os dois";
      if(!d.pix_tipo) throw "Escolha o tipo da chave PIX"; if(!d.pix_chave) throw "Informe a chave PIX"; if(!d.pix_nome||!d.pix_nome.includes(" ")) throw "Informe o nome completo de quem recebe o PIX"; if(!d.pix_banco) throw "Informe o banco da chave PIX";
      db.perfis.push({pix_tipo:d.pix_tipo,pix_chave:d.pix_chave,pix_nome:d.pix_nome,pix_banco:d.pix_banco,user_id:u.id,email:u.email,tipo:rec?"prestador":"contratante",envia:env,recebe:rec,pessoa:d.pessoa||"pf",nome:d.nome,documento:d.documento,telefone:d.telefone,cidade:d.cidade||null,
        veiculo:rec?d.veiculo:null,placa:rec?d.placa.toUpperCase():null,modelo:rec?(d.modelo||null):null,cnh_validade:rec?d.cnh_validade:null,
        status:"pendente",motivo:null,convite:c.codigo,criado_em:now,atualizado_em:now});
      db.membros=db.membros.filter(m=>m.user_id!==u.id); db.membros.push({user_id:u.id,email:u.email,papel:rec?"prestador":"contratante",ativo:false}); c.usos++; return c.tipo; },
    atualizar_cadastro(db,a){ const u=me(db); const p=db.perfis.find(p=>p.user_id===u.id); if(!["pendente","recusado"].includes(p.status)) throw "Cadastro aprovado: para mudar dados, fale com a RL";
      Object.assign(p,a.p_dados,{status:"pendente",motivo:null,atualizado_em:new Date().toISOString()}); return null; },
    decidir_cadastro(db,a){ if(!isAdmin(db)) throw "Apenas administradores"; const p=db.perfis.find(p=>p.user_id===a.p_user);
      if(!a.p_aprovar&&!(a.p_motivo||"").trim()) throw "Informe o motivo da recusa";
      p.status=a.p_aprovar?"aprovado":"recusado"; p.motivo=a.p_aprovar?null:a.p_motivo; db.membros.find(m=>m.user_id===a.p_user).ativo=!!a.p_aprovar; return null; },
    bloquear_usuario(db,a){ db.membros.find(m=>m.user_id===a.p_user).ativo=false; const p=db.perfis.find(p=>p.user_id===a.p_user); if(p) p.status="bloqueado"; return null; },
    desbloquear_cadastro(db,a){ db.membros.find(m=>m.user_id===a.p_user).ativo=true; db.perfis.find(p=>p.user_id===a.p_user).status="aprovado"; return null; },
    cfg_usuarios(db){ if(!isDono(db)) throw "Apenas a RL (dono do sistema) pode fazer isso";
      return db.users.map(u=>{ const m=db.membros.find(x=>x.user_id===u.id)||{}; const p=db.perfis.find(x=>x.user_id===u.id)||{};
        return {user_id:u.id,email:u.email,nome:p.nome||null,papel:m.papel||null,tipo:p.tipo||null,ativo:!!m.ativo,cadastro:p.status||null,removido_em:m.removido_em||null,criado_em:"2026-11-01T00:00:00Z",ultimo_acesso:u.ult||null,envia:!!p.envia,gestao:!!p.gestao}; }); },
    cfg_gestao(db,a){ if(!isDono(db)) throw "Apenas a RL (dono do sistema) pode fazer isso"; const p=db.perfis.find(x=>x.user_id===a.p_user&&x.envia); if(!p) throw "O painel de gestão é para quem envia serviços"; p.gestao=a.p_ligar; return "ok"; },
    minha_marca(db,a){ const p=db.perfis.find(x=>x.user_id===me(db).id); if(!p) throw "Complete seu cadastro primeiro"; if(!p.envia) throw "A marca nos recibos é para quem envia serviços"; p.marca_nome=(a.p_nome||"").trim()||null; if(a.p_logo!==null&&a.p_logo!==undefined) p.marca_logo=a.p_logo||null; return "ok"; },
    gestao_servicos(db,a){ const p=db.perfis.find(x=>x.user_id===me(db).id); if(!p||!p.gestao) throw "O painel de gestão não está liberado para sua conta. Fale com a MegaEntregas.";
      return (db.servicos||[]).filter(s=>s.criado_por===p.user_id).map(s=>{ const q=db.perfis.find(x=>x.user_id===s.pego_por)||{}; return {...s,espera_min:s.espera_min||0,espera_valor:s.espera_valor||0,quem_pegou:q.nome||null,placa:q.placa||null}; }); },
    cfg_definir_papel(db,a){ if(!isDono(db)) throw "Apenas a RL (dono do sistema) pode fazer isso"; const u=db.users.find(x=>x.email===a.p_email.toLowerCase()); if(!u) throw "O e-mail "+a.p_email+" ainda não criou o acesso no sistema";
      if(u.id===me(db).id) throw "Você não pode mudar o seu próprio perfil"; if(db.perfis.some(p=>p.user_id===u.id)) throw "Este e-mail é de uma empresa/motoboy.";
      let m=db.membros.find(x=>x.user_id===u.id); if(!m){ m={user_id:u.id,email:u.email}; db.membros.push(m); } Object.assign(m,{papel:a.p_papel,ativo:true,removido_em:null}); return "ok"; },
    cfg_bloquear(db,a){ if(!isDono(db)) throw "Apenas a RL (dono do sistema) pode fazer isso"; if(a.p_user===me(db).id) throw "Você não pode bloquear a si mesmo";
      const m=db.membros.find(x=>x.user_id===a.p_user); if(m&&m.removido_em) throw "Este usuário foi removido. Use Restaurar."; if(m) m.ativo=!a.p_bloquear;
      const p=db.perfis.find(x=>x.user_id===a.p_user); if(p) p.status=a.p_bloquear?"bloqueado":(p.status==="bloqueado"?"aprovado":p.status); db.__log=(db.__log||[]).concat("bloq:"+a.p_user+":"+a.p_bloquear); return "ok"; },
    cfg_remover(db,a){ if(!isDono(db)) throw "Apenas a RL (dono do sistema) pode fazer isso"; if(a.p_user===me(db).id) throw "Você não pode remover a si mesmo";
      let m=db.membros.find(x=>x.user_id===a.p_user); const u=db.users.find(x=>x.id===a.p_user); const p=db.perfis.find(x=>x.user_id===a.p_user);
      if(a.p_remover){ if(!m){ m={user_id:u.id,email:u.email,papel:p?p.tipo:"funcionario"}; db.membros.push(m); } m.ativo=false; m.removido_em=new Date().toISOString(); if(p) p.status="bloqueado"; }
      else { m.ativo=true; m.removido_em=null; if(p&&p.status==="bloqueado") p.status="aprovado"; } return "ok"; },
    cfg_salvar(db,a){ if(!isDono(db)) throw "Apenas a RL (dono do sistema) pode fazer isso"; const r=db.config_sistema.find(x=>x.chave===a.p_chave);
      if(a.p_chave==="distribuicao" && a.p_valor.raio_maximo_km<a.p_valor.raio_inicial_km) throw "Valores de distribuição inválidos";
      r.valor=a.p_valor; r.atualizado_em=new Date().toISOString(); return "ok"; },
    servico_soltar(db,a){ const u=me(db); const p=db.perfis.find(x=>x.user_id===u.id); if(!p||p.status!=="aprovado") throw "Seu cadastro precisa estar aprovado"; if(!p.envia) throw "Seu cadastro não está marcado para enviar serviços";
      const d=a.p; db.servicos=db.servicos||[]; const num=Math.max(0,...db.servicos.map(x=>x.numero||0))+1, id="s-"+num; db.servicos.push({id,numero:num,criado_por:u.id,retirada:d.retirada,paradas:d.paradas,km:d.km,minutos:d.minutos,veiculo:d.veiculo,valor:d.valor,agendado_para:d.agendado_para,obs:d.obs||null,forma_pag:d.forma_pag==="dinheiro"?"dinheiro":"pix",status:"aberto",criado_em:new Date().toISOString()}); return id; },
    servico_cancelar(db,a){ const s=(db.servicos||[]).find(x=>x.id===a.p_id&&x.criado_por===me(db).id&&x.status==="aberto"); if(!s) throw "Só dá para cancelar um serviço seu que ainda está aberto"; s.status="cancelado"; return "ok"; },
    servico_aumentar(db,a){ const s=(db.servicos||[]).find(x=>x.id===a.p_id&&x.criado_por===me(db).id); if(!s) throw "Serviço não encontrado"; if(s.status!=="aberto") throw "Só dá para aumentar o valor de um serviço que ainda está aberto"; if(!(a.p_valor>s.valor)) throw "O novo valor precisa ser maior que o atual"; s.valor_inicial=s.valor_inicial||s.valor; s.valor=a.p_valor; s.aumentado_em=new Date().toISOString(); s.aumentos=(s.aumentos||0)+1; return s.valor; },
    servicos_proximos(db,a){ const u=me(db); const p=db.perfis.find(x=>x.user_id===u.id); if(!p||p.status!=="aprovado") throw "Seu cadastro precisa estar aprovado"; if(!p.recebe) throw "Seu cadastro não está marcado para receber serviços"; if(!p.disponivel) throw "Ligue o botão Disponível para receber serviços";
      db.__loc=[a.p_lat,a.p_lon]; const dk=(a1,o1,a2,o2)=>{const R=6371,r=Math.PI/180,x=Math.sin((a2-a1)*r/2)**2+Math.cos(a1*r)*Math.cos(a2*r)*Math.sin((o2-o1)*r/2)**2;return 2*R*Math.asin(Math.sqrt(x));};
      return (db.servicos||[]).filter(s=>s.status==="aberto"&&s.criado_por!==u.id&&s.veiculo===p.veiculo).map(s=>({...s,distancia_km:Math.round(dk(a.p_lat,a.p_lon,s.retirada.la,s.retirada.lo)*10)/10})).filter(s=>s.distancia_km<=3).map(s=>{ const cs=(db.candidaturas||[]).filter(c=>c.servico_id===s.id&&c.status==="ativa"); return {...s,candidatos:cs.length,max_candidatos:3,eu_candidato:cs.some(c=>c.prestador_id===u.id)}; }).filter(s=>s.eu_candidato||s.candidatos<3).sort((x,y)=>x.distancia_km-y.distancia_km); },
    minha_disponibilidade(db,a){ const p=db.perfis.find(x=>x.user_id===me(db).id); p.disponivel=!!a.p_ligar; if(!a.p_ligar) (db.candidaturas||[]).forEach(c=>{ if(c.prestador_id===p.user_id&&c.status==="ativa") c.status="desistiu"; }); return p.disponivel; },
    servico_candidatar(db,a){ if(!(db.perfis.find(x=>x.user_id===me(db).id)||{}).disponivel) throw "Ligue o botão Disponível para receber serviços"; const u=me(db); db.candidaturas=db.candidaturas||[]; const s=db.servicos.find(x=>x.id===a.p_id); if(!s||s.status!=="aberto") throw "Este serviço não está mais aberto";
      if(db.candidaturas.some(c=>c.servico_id===a.p_id&&c.prestador_id===u.id&&c.status==="ativa")) return "ja";
      if(db.candidaturas.filter(c=>c.servico_id===a.p_id&&c.status==="ativa").length>=3) throw "Este serviço já tem 3 candidatos";
      db.candidaturas=db.candidaturas.filter(c=>!(c.servico_id===a.p_id&&c.prestador_id===u.id)); db.candidaturas.push({servico_id:a.p_id,prestador_id:u.id,status:"ativa",distancia_km:1.2,criado_em:new Date().toISOString()}); return "ok"; },
    servico_desistir(db,a){ const c=(db.candidaturas||[]).find(c=>c.servico_id===a.p_id&&c.prestador_id===me(db).id&&c.status==="ativa"); if(!c) throw "Você não tem candidatura ativa neste serviço"; c.status="desistiu"; return "ok"; },
    servico_candidatos(db,a){ return (db.candidaturas||[]).filter(c=>c.servico_id===a.p_id&&["ativa","escolhida"].includes(c.status)).map(c=>{ const p=db.perfis.find(x=>x.user_id===c.prestador_id)||{}; return {...c,nome:p.nome,veiculo:p.veiculo,modelo:p.modelo,placa:(p.placa||"").slice(0,3)+"-"+(p.placa||"").slice(-2),cidade:p.cidade,servicos_feitos:0}; }); },
    servico_escolher(db,a){ const s=db.servicos.find(x=>x.id===a.p_id&&x.criado_por===me(db).id); if(!s) throw "Serviço não encontrado"; if(s.status!=="aberto") throw "Este serviço já tem alguém escolhido";
      s.status="aceito"; s.pego_por=a.p_prestador; db.candidaturas.filter(c=>c.servico_id===a.p_id&&c.status==="ativa").forEach(c=>c.status=c.prestador_id===a.p_prestador?"escolhida":"recusada");
      db.mensagens=db.mensagens||[]; db.mensagens.push({id:db.mensagens.length+1,servico_id:a.p_id,autor:me(db).id,texto:"Serviço confirmado. Combine os detalhes da retirada por aqui.",criado_em:new Date().toISOString()}); return "ok"; },
    servicos_previsoes(db,a){ const o={}; (a.p_ids||[]).forEach(id=>{ const s=(db.servicos||[]).find(x=>x.id===id); if(!s) return; const t=m=>new Date(Date.now()+m*60000).toISOString();
      o[id]={status:s.status,gps:true,minutos_rota:s.minutos||12,retirada:{e:s.retirada.e,prev:s.status==="aberto"?null:(s.retirada.feito_em?null:t(9)),real:s.retirada.feito_em||null},entregas:s.paradas.map((p,i)=>({e:p.e,prev:s.status==="aberto"?null:(p.feito_em?null:t(25+i*10)),real:p.feito_em||null}))}; }); return o; },
    meu_pix(db,a){ const p=db.perfis.find(x=>x.user_id===me(db).id); if(!p) throw "Complete seu cadastro primeiro"; Object.assign(p,{pix_tipo:a.p_dados.pix_tipo,pix_chave:a.p_dados.pix_chave,pix_nome:a.p_dados.pix_nome,pix_banco:a.p_dados.pix_banco}); return "ok"; },
    veiculos_liberados(db){ const r=(db.config_sistema||[]).find(x=>x.chave==="veiculos"); return r?r.valor:{moto:true,carro:false,utilitario:false,caminhao:false}; },
    meus_ajustes(db,a){ const p=db.perfis.find(x=>x.user_id===me(db).id); if(!p) throw "Seu cadastro precisa estar aprovado"; if(!(a.p_quer||[]).length) throw "Escolha pelo menos um tipo de serviço"; p.quer_veiculos=a.p_quer; return "ok"; },
    adm_uso(db,a){ if(!isAdmin(db)) throw "Apenas administradores"; if(!a.p_envia&&!a.p_recebe) throw "O cadastro precisa enviar, receber ou os dois"; const p=db.perfis.find(x=>x.user_id===a.p_user); if(!p) throw "Cadastro não encontrado"; if(a.p_recebe&&!p.veiculo) throw "Para receber serviços o cadastro precisa ter veículo"; p.envia=a.p_envia; p.recebe=a.p_recebe; return "ok"; },
    meu_uso_envia(db,a){ const p=db.perfis.find(x=>x.user_id===me(db).id); if(!p) throw "Cadastro não encontrado"; if(p.status!=="aprovado") throw "Seu cadastro precisa estar aprovado"; if(!a.p_ligar&&!p.recebe) throw "Seu cadastro é só de envio"; p.envia=a.p_ligar; return "ok"; },
    servico_pix(db,a){ const s=db.servicos.find(x=>x.id===a.p_id); if(!s||(s.criado_por!==me(db).id&&!isAdmin(db))) throw "Serviço não encontrado"; if(s.status!=="concluido") throw "O PIX aparece quando o serviço for concluído";
      const p=db.perfis.find(x=>x.user_id===s.pego_por)||{}; return {quem:p.nome,pix_tipo:p.pix_tipo,pix_chave:p.pix_chave,pix_nome:p.pix_nome,pix_banco:p.pix_banco,telefone:p.telefone,valor:Number(s.valor)+Number(s.espera_valor||0),frete:s.valor,espera:s.espera_valor||0,pago_em:s.pago_em||null,recebido_em:s.recebido_em||null,comprovante:s.pag_comprovante||null,forma_pag:s.forma_pag||"pix"}; },
    servico_paguei(db,a){ const s=db.servicos.find(x=>x.id===a.p_id&&x.criado_por===me(db).id); if(!s) throw "Serviço não encontrado"; if(s.status!=="concluido") throw "O serviço ainda não foi concluído"; if(s.recebido_em) throw "O recebimento já foi confirmado";
      if(a.p_comprovante&&!a.p_comprovante.startsWith(s.id+"/")) throw "Comprovante inválido"; s.pago_em=s.pago_em||new Date().toISOString(); if(a.p_comprovante) s.pag_comprovante=a.p_comprovante; return "ok"; },
    servico_recebi(db,a){ const s=db.servicos.find(x=>x.id===a.p_id); if(!s||(s.pego_por!==me(db).id&&!isAdmin(db))) throw "Serviço não encontrado"; s.recebido_em=s.recebido_em||new Date().toISOString(); return "ok"; },
    servico_nao_recebi(db,a){ const s=db.servicos.find(x=>x.id===a.p_id&&x.pego_por===me(db).id); if(!s) throw "Serviço não encontrado"; if(s.recebido_em) throw "Você já confirmou o recebimento deste serviço"; s.nao_recebi_em=new Date().toISOString(); s.nao_recebi_obs=a.p_obs||null; return "ok"; },
    minhas_baixas_pendentes(db){ const u=me(db); return (db.servicos||[]).filter(s=>s.pego_por===u.id&&s.status==="concluido"&&!s.recebido_em&&!s.nao_recebi_em&&Date.now()-new Date(s.concluido_em)>48*3600e3).length; },
    adm_alertas_pagamento(db){ if(!isAdmin(db)) throw "Apenas administradores"; return (db.servicos||[]).filter(s=>s.status==="concluido"&&!s.recebido_em&&(s.nao_recebi_em||Date.now()-new Date(s.concluido_em)>48*3600e3)).map(s=>{ const pe=db.perfis.find(x=>x.user_id===s.criado_por)||{}, pp=db.perfis.find(x=>x.user_id===s.pego_por)||{};
      return {id:s.id,numero:s.numero,tipo:s.nao_recebi_em?"nao_recebi":"sem_baixa",quem_enviou:pe.nome,quem_pegou:pp.nome,tel_enviou:pe.telefone,tel_pegou:pp.telefone,valor:Number(s.valor)+Number(s.espera_valor||0),concluido_em:s.concluido_em,pago_em:s.pago_em||null,pag_comprovante:s.pag_comprovante||null,nao_recebi_em:s.nao_recebi_em||null,nao_recebi_obs:s.nao_recebi_obs||null}; }); },
    meus_trabalhos(db){ const u=me(db); return (db.candidaturas||[]).filter(c=>c.prestador_id===u.id&&["ativa","escolhida","recusada"].includes(c.status)).map(c=>{ const s=db.servicos.find(x=>x.id===c.servico_id); const pe=db.perfis.find(x=>x.user_id===s.criado_por)||{}; return {...s,minha:c.status,quem_enviou:s.pego_por===u.id?pe.nome:null}; }); },
    chat_listar(db,a){ const u=me(db); const s=db.servicos.find(x=>x.id===a.p_id); if(!s||!(s.criado_por===u.id||s.pego_por===u.id||isAdmin(db))) throw "Conversa não encontrada";
      return (db.mensagens||[]).filter(m=>m.servico_id===a.p_id&&m.id>(a.p_depois||0)).map(m=>{ const p=db.perfis.find(x=>x.user_id===m.autor); return {...m,nome:p?p.nome:"RL",papel:m.autor===s.criado_por?"enviou":m.autor===s.pego_por?"pegou":"rl"}; }); },
    chat_enviar(db,a){ const u=me(db); const s=db.servicos.find(x=>x.id===a.p_id); if(!s||!(s.criado_por===u.id||s.pego_por===u.id||isAdmin(db))) throw "Conversa não encontrada"; if(!s.pego_por) throw "O chat abre quando alguém for escolhido para o serviço";
      db.mensagens=db.mensagens||[]; const id=db.mensagens.length+1; db.mensagens.push({id,servico_id:a.p_id,autor:u.id,texto:a.p_texto,criado_em:new Date().toISOString()}); return id; },
    servico_iniciar(db,a){ const u=me(db); const s=db.servicos.find(x=>x.id===a.p_id&&x.pego_por===u.id); if(!s) throw "Serviço não encontrado"; if(s.status==="aceito"){ s.status="em_andamento"; s.rastreio_ver="v".repeat(32); s.iniciado_em=new Date().toISOString(); } return {moto:"m".repeat(32),ver:s.rastreio_ver}; },
    servico_meu_rastreio(db,a){ const s=db.servicos.find(x=>x.id===a.p_id&&x.pego_por===me(db).id&&x.status==="em_andamento"); return s?{moto:"m".repeat(32),ver:s.rastreio_ver}:null; },
    rastreio_posicao(db,a){ db.__pos=(db.__pos||0)+1; return "ok"; },
    servico_chegou(db,a){ const s=db.servicos.find(x=>x.id===a.p_id&&x.pego_por===me(db).id); if(s.status!=="em_andamento") throw "Inicie o serviço primeiro"; const p=a.p_ponto===0?s.retirada:s.paradas[a.p_ponto-1];
      if(a.p_ponto>0&&!s.retirada.feito_em) throw "Faça a retirada primeiro"; if(!p.chegou_em) p.chegou_em=new Date(Date.now()-(db.__atraso||0)*60000).toISOString(); return "ok"; },
    servico_retirada(db,a){ const s=db.servicos.find(x=>x.id===a.p_id&&x.pego_por===me(db).id); const r=s.retirada; r.feito_em=new Date().toISOString(); r.nome=a.p_nome; r.chegou_em=r.chegou_em||r.feito_em;
      r.espera_min=Math.max(0,Math.ceil((new Date(r.feito_em)-new Date(r.chegou_em))/60000)-15); s.espera_min=(s.espera_min||0)+r.espera_min; s.espera_valor=s.espera_min*0.5; return "ok"; },
    servico_entrega(db,a){ const s=db.servicos.find(x=>x.id===a.p_id&&x.pego_por===me(db).id); if(!s.retirada.feito_em) throw "Faça a retirada primeiro"; if(String(a.p_rg).replace(/\W/g,"").length<5) throw "Digite o RG de quem recebeu";
      const p=s.paradas[a.p_ponto-1]; p.feito_em=new Date().toISOString(); p.nome=a.p_nome; p.rg=String(a.p_rg).replace(/\W/g,"").toUpperCase(); p.chegou_em=p.chegou_em||p.feito_em; p.espera_min=0;
      if(s.paradas.every(x=>x.feito_em)){ s.status="concluido"; s.concluido_em=new Date().toISOString(); return "concluido"; } return "ok"; },
    rastreio_varios(db,a){ return (db.__rast||[]).filter(r=>a.p_vers.includes(r.v)); },
    adm_motoboys(db){ if(!isAdmin(db)) throw "Apenas administradores"; return window.DEMO_FROTA?window.DEMO_FROTA(db):(db.__motoboys||[]); },
    adm_servicos(db){ if(!isAdmin(db)) throw "Apenas administradores"; return (db.servicos||[]).map(s=>{ const pe=db.perfis.find(x=>x.user_id===s.criado_por)||{}, pp=db.perfis.find(x=>x.user_id===s.pego_por)||{};
      return {...s,quem_enviou:pe.nome,quem_pegou:pp.nome||null,candidatos:(db.candidaturas||[]).filter(c=>c.servico_id===s.id&&["ativa","escolhida"].includes(c.status)).length,mensagens:(db.mensagens||[]).filter(m=>m.servico_id===s.id).length}; }); },
    listar_usuarios(db){ return db.membros.filter(m=>!["prestador","contratante"].includes(m.papel)).map(m=>({...m,liberado:true,criado_em:new Date().toISOString()})); },
  };
  window.supabase={createClient(){
    return {
      auth:{
        onAuthStateChange(){ return {data:{subscription:{unsubscribe(){}}}}; },
        async getSession(){ return {data:{session:load().session}}; },
        async signUp({email}){ const db=load(); if(db.users.some(u=>u.email===email)) return err("User already registered"); const u={id:uid(),email}; db.users.push(u); db.session={user:u}; save(db); return {data:{session:db.session},error:null}; },
        async signInWithPassword({email}){ const db=load(); const u=db.users.find(u=>u.email===email); if(!u) return err("Invalid login credentials"); db.session={user:u}; save(db); return {data:{session:db.session},error:null}; },
        async signOut(){ const db=load(); db.session=null; save(db); return {error:null}; },
        async resetPasswordForEmail(){ return {error:null}; }, async updateUser(){ return {error:null}; }
      },
      from(t){ return new Q(t); },
      async rpc(n,a){ const db=load(), antes=JSON.stringify(db); try{ if(!rpcs[n]) return {data:null,error:null}; const r=rpcs[n](db,a||{}); if(JSON.stringify(db)!==antes) save(db); return {data:r,error:null}; }catch(e){ return err(String(e.message||e)); } },
      storage:{ from(bk){ return {
        async upload(path,blob){ const db=load(); const u=me(db); if(bk!=="pagamentos"&&!path.startsWith(u.id+"/")) return err("rls"); db.storage[path]={size:blob.size,type:blob.type}; save(db); return {data:{path},error:null}; },
        async remove(paths){ const db=load(); paths.forEach(p=>delete db.storage[p]); save(db); return {data:null,error:null}; },
        async createSignedUrl(path){ return {data:{signedUrl:"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg'/>"},error:null}; },
        async createSignedUrls(paths){ return {data:paths.map(p=>({signedUrl:/\.pdf$/.test(p)?"data:application/pdf;base64,JVBERi0=":"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='300' height='180'><rect width='300' height='180' fill='%23e5e7eb'/><text x='150' y='95' font-size='18' text-anchor='middle'>"+encodeURIComponent(p.split('/')[1])+"</text></svg>"})),error:null}; }
      }; } },
      channel(){ const c={on(){return c;},subscribe(){return c;}}; return c; }, removeChannel(){}
    };
  }};
})();
