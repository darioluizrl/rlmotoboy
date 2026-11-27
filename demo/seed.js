/* Soltou, Pegou · modo DEMONSTRAÇÃO: dados fictícios, frota em movimento e GPS simulado.
   Tudo roda só neste navegador. Nenhum dado vai para o banco real. */
(function(){
  const K="__demodb", VER=3;
  const BASE={lat:-23.6944, lon:-46.5654};            /* São Bernardo do Campo (centro) */
  const now=()=>new Date().toISOString();
  const mins=m=>new Date(Date.now()-m*60000).toISOString();

  /* frota fictícia: nomes, placas e trajetos gerados (sempre iguais) */
  const NOMES=["Carlos","Rafael","Bruno","Diego","Marcos","Thiago","Felipe","Lucas","André","Rodrigo","Gustavo","Leandro","Fábio","Renato","Vinícius","Eduardo","Jonas","Paulo","Sérgio","Wellington","Anderson","Ricardo","Leonardo","Daniel","Matheus","Gabriel","Henrique","Júlio","Robson","Alex","Márcio","Otávio","Igor","Caio","Samuel","Tiago","Wagner","Elton","Hugo","Pedro","Juliana","Patrícia","Aline","Fernanda"];
  const SOBR=["Silva","Santos","Oliveira","Souza","Lima","Pereira","Costa","Rodrigues","Almeida","Nascimento","Carvalho","Gomes","Martins","Araújo","Ribeiro","Barbosa","Rocha","Dias","Moreira","Teixeira"];
  let sd=7; const rnd=()=>{ sd=(sd*16807)%2147483647; return (sd-1)/2147483646; };
  const L="ABCDEFGHJKLMNPRSTUVWXYZ"; const placa=()=>L[Math.floor(rnd()*23)]+L[Math.floor(rnd()*23)]+L[Math.floor(rnd()*23)]+Math.floor(rnd()*10)+L[Math.floor(rnd()*23)]+Math.floor(rnd()*10)+Math.floor(rnd()*10);
  const FROTA=Array.from({length:44},(_,i)=>({
    user_id:"f-"+i, nome:NOMES[i%NOMES.length]+" "+SOBR[Math.floor(rnd()*SOBR.length)], veiculo:"moto", placa:placa(),
    telefone:"119"+String(80000000+Math.floor(rnd()*9999999)),
    clat:-23.595-rnd()*0.135, clon:-46.645+rnd()*0.15, rk:0.6+rnd()*2.2, ph:rnd()*6.28, ph2:rnd()*6.28, k:0.8+rnd()*0.7, sl:rnd()*7
  }));
  window.DEMO_FROTA=function(db){
    const t=Date.now()/1000, out=[];
    FROTA.forEach((f,i)=>{
      const slot=Math.floor(t/75+f.sl)%7, sit=slot<3?"em_servico":slot===3?"escolhido":"livre";
      const v=(sit==="livre"?11:27)/3600, w=v/f.rk;                         /* km/s → rad/s */
      const a=w*t+f.ph, kmLat=1/110.6, kmLon=1/101.5;
      const lat=f.clat+f.rk*kmLat*Math.sin(a*f.k+f.ph2), lon=f.clon+f.rk*kmLon*Math.cos(a);
      out.push({user_id:f.user_id, nome:f.nome, situacao:sit, lat, lon, atualizado_em:new Date(Date.now()-((i*7)%9)*1000).toISOString(),
        veiculo:f.veiculo, placa:f.placa, telefone:f.telefone, servico_numero:sit==="livre"?null:120+i, rastreio_ver:null, agora:now()});
    });
    const c=db.perfis.find(p=>p.user_id==="moto1"), s=(db.servicos||[]).find(x=>x.pego_por==="moto1"&&["aceito","em_andamento"].includes(x.status));
    if(c&&c.disponivel){ const g=demoGps(); out.unshift({user_id:"moto1",nome:c.nome,situacao:s?(s.status==="em_andamento"?"em_servico":"escolhido"):"livre",lat:g.lat,lon:g.lon,atualizado_em:now(),veiculo:"moto",placa:c.placa,telefone:c.telefone,servico_numero:s?s.numero:null,rastreio_ver:null,agora:now()}); }
    return out;
  };

  /* GPS simulado do motoboy da demonstração (a página de apresentação move o ponto) */
  function demoGps(){ try{ const g=JSON.parse(localStorage.getItem("__demogps")||"null"); if(g) return g; }catch(e){} return {lat:BASE.lat+0.004, lon:BASE.lon-0.003}; }
  window.demoGps=demoGps;
  const pos=()=>{ const g=demoGps(); return {coords:{latitude:g.lat,longitude:g.lon,accuracy:8},timestamp:Date.now()}; };
  try{ Object.defineProperty(navigator,"geolocation",{configurable:true,value:{
    getCurrentPosition(ok){ setTimeout(()=>ok(pos()),150); },
    watchPosition(ok){ ok(pos()); return setInterval(()=>ok(pos()),3000); },
    clearWatch(id){ clearInterval(id); }
  }}); }catch(e){}

  /* dados iniciais da demonstração */
  window.DEMO_SEED=function(forcar){
    let db=null; try{ db=JSON.parse(localStorage.getItem(K)||"null"); }catch(e){}
    if(db && db.__v===VER && !forcar) return;
    const U=(id,email)=>({id,email});
    const P=(o)=>Object.assign({status:"aprovado",pessoa:"pf",documento:"00000000000",telefone:"11900000000",cidade:"São Bernardo do Campo",criado_em:mins(9000),aprovado_em:mins(8000),disponivel:false,gestao:false,
      pix_tipo:"email",pix_chave:o.email,pix_nome:o.nome,pix_banco:"Banco Demonstração"},o);
    const sv=(n,ret,ent,km,min,valor,fp,ago,obs)=>({id:"d-"+n,numero:n,criado_por:"loja",retirada:{e:ret[0],la:ret[1],lo:ret[2]},paradas:[{e:ent[0],la:ent[1],lo:ent[2],t:"entrega"}],
      km,minutos:min,veiculo:"moto",valor,forma_pag:fp,status:"aberto",criado_em:mins(ago),obs:obs||null});
    db={__v:VER, session:null,
      users:[U("dono","dono@demo.megaentregas"),U("loja","loja@demo.megaentregas"),U("moto1","carlos@demo.megaentregas")],
      membros:[{user_id:"dono",email:"dono@demo.megaentregas",papel:"dono",ativo:true},{user_id:"loja",email:"loja@demo.megaentregas",papel:"contratante",ativo:true},{user_id:"moto1",email:"carlos@demo.megaentregas",papel:"prestador",ativo:true}],
      perfis:[
        P({user_id:"loja",email:"loja@demo.megaentregas",tipo:"contratante",pessoa:"pj",nome:"Padaria Bom Pão (demonstração)",envia:true,recebe:false,marca_nome:"Padaria Bom Pão"}),
        P({user_id:"moto1",email:"carlos@demo.megaentregas",tipo:"prestador",nome:"Carlos Andrade",envia:false,recebe:true,veiculo:"moto",placa:"DMO2A26",modelo:"Honda CG 160",disponivel:true})
      ],
      documentos:[],convites:[],docs:[],storage:{},candidaturas:[],mensagens:[],rastreios:[],
      config_sistema:[{chave:"veiculos",valor:{moto:true,carro:false,utilitario:false,caminhao:false}},{chave:"creditos",valor:{valor_credito:0.5,creditos_envia:2,creditos_pega:1}},
        {chave:"espera",valor:{minutos_gratis:15,valor_minuto:0.5}},{chave:"distribuicao",valor:{raio_inicial_km:3,minutos_ate_ampliar:5,raio_maximo_km:10,minutos_para_todos:10,max_candidatos:3}}],
      servicos:[
        sv(101,["Rua Marechal Deodoro, 1500 - Centro, São Bernardo do Campo",-23.7095,-46.5505],["Av. Kennedy, 800 - Jardim do Mar, São Bernardo do Campo",-23.6960,-46.5565],2.8,9,22,"pix",3,"Envelope com documentos"),
        sv(102,["Av. Senador Vergueiro, 1000 - Centro, São Bernardo do Campo",-23.6990,-46.5530],["Rua Jurubatuba, 500 - Centro, São Bernardo do Campo",-23.7080,-46.5480],3.2,10,18,"pix",6),
        sv(103,["Av. Pereira Barreto, 1200 - Baeta Neves, São Bernardo do Campo",-23.6905,-46.5420],["Rua Tiradentes, 300 - Santa Terezinha, São Bernardo do Campo",-23.6985,-46.5650],3.5,11,15,"dinheiro",8,"Pacote pequeno")
      ]};
    localStorage.setItem(K,JSON.stringify(db)); localStorage.removeItem("__demogps");
  };
  window.DEMO_SEED(false);
})();
