// Upco InsurGest — helpers compartidos entre app/index.html (agente) y p/index.html (portal del cliente).
// Cargar como <script src="../shared.js"></script> ANTES del bloque type="text/babel".
const SUPABASE_URL="https://pxcvckqahkjlizgotvqw.supabase.co";
const SUPABASE_ANON_KEY="sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I";
const sb=window.supabase.createClient(SUPABASE_URL,SUPABASE_ANON_KEY);

// Llave pública VAPID — no es secreta, va embebida en el cliente a propósito (la privada vive solo en Supabase Vault + la Edge Function).
const VAPID_PUBLIC_KEY="BCYtFn7CJtQCso_ugc9IyzHvi_85U7yWCloYVqvayT0Ta8eFIjLv-DwIzH7f3IPPNTJPGwvISXS4tFG6s5uOsUo";

function urlBase64ToUint8Array(base64String){
  const padding="=".repeat((4-base64String.length%4)%4);
  const base64=(base64String+padding).replace(/-/g,"+").replace(/_/g,"/");
  const rawData=atob(base64);
  return Uint8Array.from([...rawData].map(c=>c.charCodeAt(0)));
}

// Registra el service worker, pide permiso de notificaciones y suscribe al cliente.
// Devuelve "ok", "no-soportado" o "rechazado" — nunca truena aunque el navegador no soporte push.
async function suscribirPush(token){
  if(!("serviceWorker" in navigator)||!("PushManager" in window))return"no-soportado";
  try{
    const registro=await navigator.serviceWorker.register("../sw.js");
    const permiso=await Notification.requestPermission();
    if(permiso!=="granted")return"rechazado";
    let suscripcion=await registro.pushManager.getSubscription();
    if(!suscripcion){
      suscripcion=await registro.pushManager.subscribe({
        userVisibleOnly:true,
        applicationServerKey:urlBase64ToUint8Array(VAPID_PUBLIC_KEY)
      });
    }
    const json=suscripcion.toJSON();
    await sb.rpc("portal_suscribir_push",{p_token:token,p_endpoint:json.endpoint,p_p256dh:json.keys.p256dh,p_auth:json.keys.auth});
    return"ok";
  }catch(e){
    return"rechazado";
  }
}

// Igual que suscribirPush, pero para un agente ya autenticado (usa su sesión, no un token de liga).
async function suscribirPushAgente(){
  if(!("serviceWorker" in navigator)||!("PushManager" in window))return"no-soportado";
  try{
    const registro=await navigator.serviceWorker.register("../sw.js");
    const permiso=await Notification.requestPermission();
    if(permiso!=="granted")return"rechazado";
    let suscripcion=await registro.pushManager.getSubscription();
    if(!suscripcion){
      suscripcion=await registro.pushManager.subscribe({
        userVisibleOnly:true,
        applicationServerKey:urlBase64ToUint8Array(VAPID_PUBLIC_KEY)
      });
    }
    const json=suscripcion.toJSON();
    await sb.rpc("agente_suscribir_push",{p_endpoint:json.endpoint,p_p256dh:json.keys.p256dh,p_auth:json.keys.auth});
    return"ok";
  }catch(e){
    return"rechazado";
  }
}

// ============ BLOQUEO LOCAL (NIP + huella/rostro) ============
// OJO con el alcance de esto: es un candado del DISPOSITIVO, igual que el de Homey. Sirve para
// que quien agarre tu teléfono desbloqueado no vea tus datos. NO es seguridad de servidor: quien
// borre el localStorage lo brinca. Por eso solo se usa ENCIMA de algo que ya autentica de verdad
// (la sesión del agente, o el NIP de servidor del cliente) — nunca como único candado.
const lockKey=(id)=>`upco_ig_lock_${id}`;
const leerLock=(id)=>{try{return JSON.parse(localStorage.getItem(lockKey(id))||"null");}catch(e){return null;}};
const guardarLock=(id,cfg)=>{try{localStorage.setItem(lockKey(id),JSON.stringify(cfg));}catch(e){}};
const borrarLock=(id)=>{try{localStorage.removeItem(lockKey(id));}catch(e){}};

async function hashNip(nip){
  const buf=await crypto.subtle.digest("SHA-256",new TextEncoder().encode("upco_ig_salt_"+nip));
  return Array.from(new Uint8Array(buf)).map(b=>b.toString(16).padStart(2,"0")).join("");
}
const aB64=buf=>btoa(String.fromCharCode.apply(null,new Uint8Array(buf)));
const deB64=str=>Uint8Array.from(atob(str),c=>c.charCodeAt(0));

async function biometriaDisponible(){
  try{return !!window.PublicKeyCredential&&await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();}
  catch(e){return false;}
}
async function registrarBiometria(id,nombre){
  const challenge=crypto.getRandomValues(new Uint8Array(32));
  const cred=await navigator.credentials.create({publicKey:{
    challenge, rp:{name:"Upco InsurGest"},
    user:{id:new TextEncoder().encode(id), name:nombre||"usuario", displayName:nombre||"Usuario"},
    pubKeyCredParams:[{type:"public-key",alg:-7},{type:"public-key",alg:-257}],
    authenticatorSelection:{authenticatorAttachment:"platform",userVerification:"required"},
    timeout:60000, attestation:"none"
  }});
  return aB64(cred.rawId);
}
async function verificarBiometria(credId){
  const challenge=crypto.getRandomValues(new Uint8Array(32));
  await navigator.credentials.get({publicKey:{
    challenge, allowCredentials:[{type:"public-key",id:deB64(credId)}],
    userVerification:"required", timeout:60000
  }});
  return true;
}

// true si la cuenta (agente o promotoría) puede usar su panel: suscripción activa, acceso
// extendido manualmente por el fundador, o todavía dentro de los 30 días de prueba desde su aprobación.
// accesoRed=true cuando el agente es de los primeros 5 de una promotoría con suscripción vigente
// (vía agente_estado_red().acceso_gratis) — no aplica a promotorías ni al agente 6+ en adelante,
// cuya tarifa de $249 se sigue facturando manual.
function accesoVigente(cuenta,accesoRed){
  if(accesoRed)return true;
  if(cuenta.estatus_suscripcion==="active"||cuenta.estatus_suscripcion==="trialing")return true;
  const ahora=new Date();
  if(cuenta.acceso_extendido_hasta&&ahora<=new Date(cuenta.acceso_extendido_hasta))return true;
  if(cuenta.aprobado_en){
    const finPrueba=new Date(new Date(cuenta.aprobado_en).getTime()+30*86400000);
    if(ahora<=finPrueba)return true;
  }
  return false;
}

const colorEstatus={vigente:"#16a34a",vencida:"#dc2626",renovada:"#2563eb",cancelada:"#6b7280"};
// Solo se agrega al final: renombrar una entrada existente haría que las pólizas ya guardadas
// con el texto viejo se detecten como "Otro" al editarlas.
const RAMOS_SUGERIDOS=["Auto","Vida","PPR","Gastos Médicos","Hogar",
  "Accidentes Personales","Daños","Responsabilidad Civil","Empresariales",
  "Ahorro / Inversión","Transporte","Fianzas","Viaje","Educativo","Retiro / AFORE"];
// Catálogo solo sugerido para la tarjeta del agente; en las pólizas la aseguradora sigue
// siendo texto libre porque cada agente trabaja con quien sea.
const ASEGURADORAS_MX=["GNP","AXA","Quálitas","HDI Seguros","Mapfre","Zurich","Chubb","Allianz",
  "MetLife","Seguros Monterrey New York Life","Seguros Banorte","Inbursa","Atlas","ANA Seguros",
  "Afirme","Sura","BBVA Seguros","Plan Seguro","Bupa","El Águila","Primero Seguros","Thona Seguros"];
const ESTADOS_MX=["Aguascalientes","Baja California","Baja California Sur","Campeche","Chiapas","Chihuahua","Ciudad de México","Coahuila","Colima","Durango","Estado de México","Guanajuato","Guerrero","Hidalgo","Jalisco","Michoacán","Morelos","Nayarit","Nuevo León","Oaxaca","Puebla","Querétaro","Quintana Roo","San Luis Potosí","Sinaloa","Sonora","Tabasco","Tamaulipas","Tlaxcala","Veracruz","Yucatán","Zacatecas"];

function vigenciaCalculada(p){
  if(p.estatus==="renovada"||p.estatus==="cancelada")return{label:p.estatus,dias:null};
  if(!p.fecha_fin)return{label:p.estatus,dias:null};
  const hoy=new Date();hoy.setHours(0,0,0,0);
  const fin=new Date(p.fecha_fin+"T00:00:00");
  const dias=Math.round((fin-hoy)/86400000);
  return{label:dias<0?"vencida":"vigente",dias};
}
function textoDias(dias){
  if(dias==null)return"";
  if(dias<0)return`Venció hace ${Math.abs(dias)} día${Math.abs(dias)===1?"":"s"}`;
  if(dias===0)return"Vence hoy";
  return`Vence en ${dias} día${dias===1?"":"s"}`;
}
const pesos=n=>n==null?"—":new Intl.NumberFormat("es-MX",{style:"currency",currency:"MXN",maximumFractionDigits:0}).format(n);
const fecha=d=>d?new Date(d+"T00:00:00").toLocaleDateString("es-MX",{day:"numeric",month:"short",year:"numeric"}):"—";
function formatBytes(bytes){
  if(!bytes)return"0 MB";
  const mb=bytes/(1024*1024);
  return mb>=1024?`${(mb/1024).toFixed(2)} GB`:`${mb.toFixed(1)} MB`;
}
