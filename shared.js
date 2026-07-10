// Upco InsurGest — helpers compartidos entre app/index.html (agente) y p/index.html (portal del cliente).
// Cargar como <script src="../shared.js"></script> ANTES del bloque type="text/babel".
const SUPABASE_URL="https://pxcvckqahkjlizgotvqw.supabase.co";
const SUPABASE_ANON_KEY="sb_publishable_F2WhknXrY8MLjI5ftd0H6w_-XXjej6I";
const sb=window.supabase.createClient(SUPABASE_URL,SUPABASE_ANON_KEY);

const colorEstatus={vigente:"#16a34a",vencida:"#dc2626",renovada:"#2563eb",cancelada:"#6b7280"};

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
