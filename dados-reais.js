/* Supabase real. A chave publishable não concede acesso além das políticas RLS. */
(() => {
 'use strict';
 const db=window.supabase.createClient('https://whjyvphamkbjcrdzhzoc.supabase.co','sb_publishable_EyZgqDQTSV-M-O3_l63V7Q_LFcFDl69',{auth:{storageKey:'cde-pdi-conectado-session',persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
 let viewer=null,people=[],goals=[],certs=[],access={modules:[]},authEpoch=0;
 const fmtDate=()=>{const p=new Intl.DateTimeFormat('en-CA',{timeZone:'America/Manaus',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date());return ['year','month','day'].map(k=>p.find(v=>v.type===k).value).join('-');};
 let today=fmtDate();const globalAccess=()=>!!viewer&&(viewer.is_master===true||['master','diretor','diretoria'].includes(viewer.role));
 const staff=()=>globalAccess()||['gerente','supervisor'].includes(viewer?.role);
 const manager=()=>globalAccess()||viewer?.role==='gerente';
 const canSector=s=>globalAccess()||(staff()&&!!s&&s===viewer?.sector);
 const getPerson=id=>people.find(p=>p.id===id)||{id,full_name:'Colaborador',sector:'Sem setor'};
 const scopePeople=()=>people.filter(p=>staff()?canSector(p.sector):p.id===viewer?.id);
 const scopedGoals=()=>goals.filter(g=>g.user_id===viewer?.id||(staff()&&canSector(getPerson(g.user_id).sector)));
 const scopedCerts=()=>{const ids=new Set(scopedGoals().map(g=>g.id));return certs.filter(c=>ids.has(c.goal_id));};
 const canGoal=g=>!!g&&manager()&&canSector(getPerson(g.user_id).sector);
 const goal=id=>goals.find(g=>g.id===String(id));
 const goalCert=g=>{const list=certs.filter(c=>c.goal_id===g.id);return list.find(c=>c.status==='approved')||list.find(c=>c.status==='pending')||list.sort((a,b)=>b.submitted_at.localeCompare(a.submitted_at))[0]||null;};
 function check(r){if(r.error){const err=new Error(r.error.code==='42501'?'Seu acesso não permite esta operação.':r.error.code==='23505'?'Este registro já foi enviado. Atualize a página.':r.error.message||'Não foi possível acessar os dados.');err.code=r.error.code;throw err;}return r.data;}
 async function all(table,cols){let out=[];for(let from=0;;from+=500){const rows=check(await db.from(table).select(cols).order('id').range(from,from+499));out.push(...rows);if(rows.length<500)break;}return out;}
 const clear=()=>{authEpoch++;viewer=null;people=[];goals=[];certs=[];access={modules:[]};};
 async function reload(){const epoch=authEpoch;const user=check(await db.auth.getUser())?.user;if(!user){clear();return null;}const p=check(await db.from('profiles').select('id,full_name,email,sector,position,role,is_master,avatar_url').eq('id',user.id).single());
 const [ps,gs,cs,ctx]=await Promise.all([all('profiles','id,full_name,email,sector,position,role,is_master,avatar_url'),all('goals','id,user_id,title,description,deadline,max_points,goal_type,sector,created_at'),all('certificates','id,user_id,goal_id,status,points_awarded,submitted_at,validated_at,validated_by,file_url,file_name,file_url_2,file_name_2,review_note,revision'),db.rpc('pdi_module_access_context').then(check)]);
 if(epoch!==authEpoch)throw new Error('A sessão mudou. Entre novamente.');viewer=p;people=ps;goals=gs.map(g=>({...g,id:String(g.id)}));certs=cs.map(c=>({...c,id:String(c.id),goal_id:String(c.goal_id),note:c.review_note||'',files:[['file_url','file_name'],['file_url_2','file_name_2']].filter(([k])=>c[k]).map(([k,n])=>({path:c[k],name:c[n]||'Comprovante'}))}));access=ctx;today=ctx.today||fmtDate();return viewer;}
 async function login(email,password){check(await db.auth.signInWithPassword({email:email.trim(),password}));return reload();}
 async function restore(){const r=await db.auth.getSession();if(r.error||!r.data.session)return null;try{return await reload();}catch(e){clear();throw e;}}
 async function logout(){try{check(await db.auth.signOut({scope:'local'}));}finally{clear();}}
 function stats(id=null){const gs=(id?goals.filter(g=>g.user_id===id):scopedGoals()),ids=new Set(gs.map(g=>g.id)),cs=certs.filter(c=>ids.has(c.goal_id)),approved=cs.filter(c=>c.status==='approved'),reviewed=cs.filter(c=>c.status!=='pending'),max=gs.reduce((n,g)=>n+Number(g.max_points||0),0),points=approved.reduce((n,c)=>n+Number(c.points_awarded||0),0);return{goals:gs.length,approved:new Set(approved.map(c=>c.goal_id)).size,pending:cs.filter(c=>c.status==='pending').length,points,max,coefficient:max?Math.round(points/max*100):0,adherence:reviewed.length?Math.round(approved.length/reviewed.length*100):null,people:id?1:scopePeople().length};}
 async function createGoal(v,id=null){if(!manager()||!canSector(getPerson(v.user_id).sector))throw new Error('Meta fora do seu acesso.');if(!v.title||v.title.length>120||!Number.isSafeInteger(v.max_points)||v.max_points<1||v.max_points>100000)throw new Error('Confira o título e a pontuação (1 a 100.000).');if(id){const g=goal(id);if(!canGoal(g))throw new Error('Meta fora do seu acesso.');const r=check(await db.from('goals').update({title:v.title,description:v.description,deadline:v.deadline,max_points:v.max_points}).eq('id',id).select('id'));if(!r.length)throw new Error('A meta não foi atualizada.');}else check(await db.from('goals').insert({...v,goal_type:'individual',sector:getPerson(v.user_id).sector}));await reload();}
 async function removeGoal(id){if(!canGoal(goal(id)))throw new Error('Meta fora do seu acesso.');const r=check(await db.from('goals').delete().eq('id',id).select('id'));if(!r.length)throw new Error('A meta não foi excluída.');await reload();}
 async function submitCertificate(id,files){const g=goal(id);if(g?.user_id!==viewer.id||['approved','pending'].includes(goalCert(g)?.status))throw new Error('Meta indisponível para envio.');if(files.length<1||files.length>2)throw new Error('Envie um ou dois arquivos.');const payload={user_id:viewer.id,goal_id:id,status:'pending',points_awarded:0};for(let i=0;i<files.length;i++){const f=files[i],ext=f.name.split('.').pop().toLowerCase();if(!['pdf','jpg','jpeg','png'].includes(ext)||f.size>20971520||!f.size)throw new Error('Use PDF, PNG ou JPG de até 20 MB.');const path=`${viewer.id}/${crypto.randomUUID()}.${ext}`;check(await db.storage.from('certificates').upload(path,f,{contentType:{pdf:'application/pdf',jpg:'image/jpeg',jpeg:'image/jpeg',png:'image/png'}[ext],upsert:false}));payload[i?'file_url_2':'file_url']=path;payload[i?'file_name_2':'file_name']=f.name;}check(await db.from('certificates').insert(payload));await reload();}
 async function reviewCertificate(id,status,points,note){const c=certs.find(c=>c.id===id),g=goal(c?.goal_id);if(!canGoal(g)||c.status!=='pending'||!['approved','rejected'].includes(status)||!Number.isSafeInteger(points)||points<0||points>g.max_points)throw new Error('Avaliação inválida ou fora do seu acesso.');const r=check(await db.from('certificates').update({status,points_awarded:status==='approved'?points:0,review_note:note}).eq('id',id).eq('revision',c.revision).eq('status','pending').select('id'));if(!r.length)throw new Error('Outra pessoa já avaliou. Atualize os dados.');await reload();}
 async function downloadFile(f){let path=f.path;if(/^https?:\/\//.test(path)){const u=new URL(path);if(u.origin!=='https://whjyvphamkbjcrdzhzoc.supabase.co')throw new Error('Endereço do comprovante não reconhecido.');const marker='/certificates/';if(!u.pathname.includes(marker))throw new Error('Caminho do comprovante inválido.');path=decodeURIComponent(u.pathname.split(marker)[1]);}const blob=check(await db.storage.from('certificates').download(path));const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=f.name;a.click();setTimeout(()=>URL.revokeObjectURL(url),10000);}
 async function changePassword(currentPassword,newPassword,confirmation){
  if(!viewer)throw new Error('Entre novamente para trocar sua senha.');
  if(typeof currentPassword!=='string'||!currentPassword)throw new Error('Informe sua senha atual.');
  if(typeof newPassword!=='string'||newPassword.length<8)throw new Error('A nova senha deve ter pelo menos 8 caracteres.');
  if(newPassword!==confirmation)throw new Error('A confirmação não corresponde à nova senha.');
  if(currentPassword===newPassword)throw new Error('Escolha uma senha diferente da atual.');
  const uid=viewer.id,epoch=authEpoch;
  const ensureIdentity=()=>{if(epoch!==authEpoch||viewer?.id!==uid)throw new Error('A sessão mudou. Entre novamente antes de trocar a senha.');};
  const authError=error=>{
   const messages={invalid_credentials:'Senha atual incorreta.',weak_password:'A nova senha não atende às regras de segurança. Use uma senha mais longa, com letras maiúsculas, minúsculas, números e símbolos.',same_password:'Escolha uma senha diferente da atual.',reauthentication_needed:'Entre novamente no PDI e repita a troca de senha.',reauthentication_not_valid:'A confirmação de segurança expirou. Entre novamente e tente outra vez.',over_request_rate_limit:'Muitas tentativas. Aguarde alguns minutos e tente novamente.',session_not_found:'Sua sessão expirou. Entre novamente.'};
   return new Error(messages[error?.code]||(error?.status===429?'Muitas tentativas. Aguarde alguns minutos.':'Não foi possível trocar a senha. Confira a conexão e tente novamente.'));
  };
  const identity=await db.auth.getUser();if(identity.error)throw authError(identity.error);ensureIdentity();
  if(identity.data?.user?.id!==uid||!identity.data.user.email)throw new Error('Entre com sua conta de e-mail para trocar a senha.');
  // Login recente confirma a senha atual e atende à reautenticação do Supabase.
  const verified=await db.auth.signInWithPassword({email:identity.data.user.email,password:currentPassword});
  if(verified.error)throw authError(verified.error);ensureIdentity();
  if(verified.data?.user?.id!==uid)throw new Error('Não foi possível confirmar o titular da conta.');
  const result=await db.auth.updateUser({password:newPassword,current_password:currentPassword});
  if(result.error)throw authError(result.error);
  if(result.data?.user?.id!==uid)throw new Error('Não foi possível confirmar a alteração. Entre novamente.');
 }

 async function saveAvatar(blob){if(!viewer||blob.type!=='image/webp'||blob.size>5242880)throw new Error('Imagem inválida.');const path=`${viewer.id}/${crypto.randomUUID()}.webp`;check(await db.storage.from('avatars').upload(path,blob,{contentType:'image/webp',upsert:false}));const url=db.storage.from('avatars').getPublicUrl(path).data.publicUrl;const rows=check(await db.from('profiles').update({avatar_url:url}).eq('id',viewer.id).select('id'));if(!rows.length)throw new Error('Não foi possível atualizar o perfil.');await reload();return url;}
 const moduleList=()=>access.modules.filter(m=>m.can_view||m.can_collect);
 const performanceStaff=()=>moduleList().some(m=>m.can_view);
 window.CDEModelData=Object.freeze({isLive:true,modes:[],db,get viewer(){return viewer;},get mode(){return'real';},get today(){return today;},get year(){return Number(today.slice(0,4));},get month(){return Number(today.slice(5,7));},get lastDay(){return new Date(Date.UTC(Number(today.slice(0,4)),Number(today.slice(5,7)),0)).toISOString().slice(0,10);},get people(){return people;},get goals(){return scopedGoals();},get certs(){return scopedCerts();},get myGoals(){return goals.filter(g=>g.user_id===viewer?.id);},get myCerts(){return certs.filter(c=>c.user_id===viewer?.id);},get modules(){return moduleList();},get isAreaAdmin(){return access.is_admin===true;},get performanceProfile(){return performanceStaff()?{...viewer,role:globalAccess()?viewer.role:moduleList().some(m=>m.can_correct)?'supervisor':'gerente'}:viewer;},performanceStaff,scopePeople,getPerson,goal,goalCert,stats,isGlobal:globalAccess,isStaff:staff,canManageGoals:manager,canEditGoal:canGoal,createGoal,removeGoal,submitCertificate,reviewCertificate,downloadFile,saveAvatar,changePassword,reload,login,restore,logout,reset:clear,setViewer(){if(!viewer)throw new Error('Entre com sua conta do PDI.');return viewer;},check});
 db.auth.onAuthStateChange((event)=>{if(event==='SIGNED_OUT')setTimeout(()=>{clear();window.dispatchEvent(new Event('cde-session-ended'));},0);});
})();
