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

// true si la cuenta (agente o promotoría) puede usar su panel: suscripción activa, acceso
// extendido manualmente por el fundador, o todavía dentro de los 30 días de prueba desde su aprobación.
function accesoVigente(cuenta){
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
const RAMOS_SUGERIDOS=["Auto","Vida","PPR","Gastos Médicos","Hogar"];
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
