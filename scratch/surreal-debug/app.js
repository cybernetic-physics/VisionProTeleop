import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';

const $=id=>document.getElementById(id), colors={left:0x46e2d1,right:0xffbd73,head:0xd5e7ff};
const fmt=(v,n=3)=>v==null||!Number.isFinite(v)?'—':(v>=0?'+':'')+v.toFixed(n);
const fixed=(v,n=2)=>v==null||!Number.isFinite(v)?'—':v.toFixed(n);
for(const side of ['left','right']){
 const faces=side==='left'?['x','y']:['a','b'];
 $(side+'-card').innerHTML=`<section class="panel" style="--side:var(--${side})"><div class="panel-header"><div class="side-title" style="color:var(--${side})"><span class="side-icon">${side[0].toUpperCase()}</span>${side==='left'?'Left':'Right'} controller</div><span id="${side}-status" class="badge">WAITING</span></div><div class="panel-body"><div class="position-label">Relative to current head · meters</div><div id="${side}-xyz" class="xyz mono"><span><small>X</small>—</span><span><small>Y</small>—</span><span><small>Z</small>—</span></div><div class="controls-row"><div><div class="stick" style="color:var(--${side})"><i class="stick-dot" id="${side}-stick"></i></div><div id="${side}-stick-xy" class="stick-coords mono">— / —</div></div><div class="inputs"><div class="buttons">${[...faces,'menu','thumbstick'].map(k=>`<span id="${side}-${k}" class="key unavailable" title="${k}">${k==='thumbstick'?'CLICK':k.toUpperCase()}</span>`).join('')}</div>${['trigger','grip'].map(k=>`<div class="bar-label"><span>${k[0].toUpperCase()+k.slice(1)}</span><span id="${side}-${k}-value" class="mono">—</span></div><div class="bar"><i id="${side}-${k}-bar"></i></div>`).join('')}</div></div><div class="card-foot"><span id="${side}-distance">Head distance —</span><span id="${side}-inputs">No inputs</span></div></div></section>`;
}
let latest=null,displayed=null,frozen=false,mode='world',lastArrival=0,lastSequence=null,fitPending=true,hasFrame=false;
const canvas=$('scene'), scene=new THREE.Scene();
scene.fog=new THREE.FogExp2(0x0c1420,.085);
const renderer=new THREE.WebGLRenderer({canvas,antialias:true,alpha:true});
renderer.setPixelRatio(Math.min(devicePixelRatio,2));renderer.setClearColor(0x0b1420,0);
renderer.outputColorSpace=THREE.SRGBColorSpace;renderer.toneMapping=THREE.ACESFilmicToneMapping;renderer.toneMappingExposure=1.3;
const camera=new THREE.PerspectiveCamera(43,1,.01,100);camera.position.set(1.6,1.8,-2.5);
const orbit=new OrbitControls(camera,canvas);orbit.enableDamping=true;orbit.dampingFactor=.09;orbit.target.set(0,.9,0);orbit.minDistance=.2;orbit.maxDistance=15;
scene.add(new THREE.HemisphereLight(0xbde8ff,0x182130,2.8));
const key=new THREE.DirectionalLight(0xd5edff,3);key.position.set(2,4,-3);scene.add(key);
const rim=new THREE.DirectionalLight(0x54b7b0,2);rim.position.set(-2,1,2);scene.add(rim);
const root=new THREE.Group();root.matrixAutoUpdate=false;scene.add(root);
const grid=new THREE.GridHelper(8,32,0x46657a,0x243849);grid.material.transparent=true;grid.material.opacity=.65;scene.add(grid);
const plane=new THREE.Mesh(new THREE.PlaneGeometry(80,80),new THREE.MeshStandardMaterial({color:0x0a1420,roughness:1,transparent:true,opacity:.5}));plane.rotation.x=-Math.PI/2;plane.position.y=-.005;scene.add(plane);
const originAxes=new THREE.AxesHelper(.35);scene.add(originAxes);
const mat=(color,extra={})=>new THREE.MeshStandardMaterial({color,metalness:.25,roughness:.4,...extra});
function mesh(geometry,material,parent,pos=[0,0,0]){const m=new THREE.Mesh(geometry,material);m.position.set(...pos);parent.add(m);return m;}
function outline(geometry,color,parent){const l=new THREE.LineSegments(new THREE.EdgesGeometry(geometry,25),new THREE.LineBasicMaterial({color,transparent:true,opacity:.32}));parent.add(l);return l;}
function makeHead(){const g=new THREE.Group();root.add(g);g.matrixAutoUpdate=false;
 const body=mesh(new RoundedBoxGeometry(.19,.095,.105,4,.022),mat(0xadbcc9),g);
 mesh(new RoundedBoxGeometry(.176,.076,.016,4,.014),mat(0x152a3a,{metalness:.85,roughness:.16,emissive:0x133e52,emissiveIntensity:.6}),g,[0,0,-.055]);
 const band=mesh(new THREE.TorusGeometry(.091,.004,8,48),mat(0x8aa2b6),g,[0,0,.048]);band.rotation.x=Math.PI/2;band.scale.y=1.15;
 const axes=new THREE.AxesHelper(.23);g.add(axes);
 const dir=new THREE.ArrowHelper(new THREE.Vector3(0,0,-1),new THREE.Vector3(0,0,-.08),.3,0x9bbbd3,.045,.018);g.add(dir);
 return {group:g,axes,dir};}
function makeController(side){const color=colors[side],g=new THREE.Group();root.add(g);g.matrixAutoUpdate=false;
 const shell=mat(0x27404b,{metalness:.35}),accent=mat(color,{emissive:color,emissiveIntensity:.18});
 const grip=mesh(new THREE.CapsuleGeometry(.022,.068,5,12),shell,g,[0,-.043,.01]);grip.rotation.x=-.2;
 const top=mesh(new THREE.SphereGeometry(1,24,16),shell,g,[0,.017,-.005]);top.scale.set(.039,.017,.047);
 const ring=mesh(new THREE.TorusGeometry(.031,.0018,6,40),accent,g,[0,.029,-.005]);ring.rotation.x=Math.PI/2;
 const stick=mesh(new THREE.CylinderGeometry(.008,.007,.009,16),mat(0x8599a7),g,[-.01,.035,-.014]);
 const faceA=mesh(new THREE.SphereGeometry(.005,12,8),accent.clone(),g,[.016,.034,-.019]);
 const faceB=mesh(new THREE.SphereGeometry(.005,12,8),accent.clone(),g,[.023,.032,-.003]);
 const trigger=mesh(new RoundedBoxGeometry(.02,.016,.014,2,.004),accent.clone(),g,[0,-.003,-.037]);
 const axes=new THREE.AxesHelper(.14);g.add(axes);
 const dir=new THREE.ArrowHelper(new THREE.Vector3(0,0,-1),new THREE.Vector3(),.18,color,.023,.008);g.add(dir);
 const points=new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(),new THREE.Vector3()]);
 const ray=new THREE.Line(points,new THREE.LineDashedMaterial({color,transparent:true,opacity:.45,dashSize:.025,gapSize:.012}));root.add(ray);
 const trail=new THREE.Line(new THREE.BufferGeometry(),new THREE.LineBasicMaterial({color,transparent:true,opacity:.5}));root.add(trail);
 return {group:g,axes,dir,ray,trail,history:[],stick,faceA,faceB,trigger};}
const head=makeHead(), controllers={left:makeController('left'),right:makeController('right')};
const EDGES=[[0,1],[1,2],[2,3],[3,4],[0,5],[5,6],[6,7],[7,8],[8,9],[0,10],[10,11],[11,12],[12,13],[13,14],[0,15],[15,16],[16,17],[17,18],[18,19],[0,20],[20,21],[21,22],[22,23],[23,24],[5,10],[10,15],[15,20],[0,25],[25,26]];
const hands={};for(const side of ['left','right']){
 const g=new THREE.Group();root.add(g);const joints=Array.from({length:27},()=>mesh(new THREE.SphereGeometry(.004,8,6),mat(colors[side],{emissive:colors[side],emissiveIntensity:.45}),g));
 const bones=new THREE.LineSegments(new THREE.BufferGeometry(),new THREE.LineBasicMaterial({color:colors[side],transparent:true,opacity:.55}));g.add(bones);
 hands[side]={group:g,joints,bones};
}
const GLOVE_EDGES=Array.from({length:5},(_,f)=>{const i=1+4*f;return [[0,i],[i,i+1],[i+1,i+2],[i+2,i+3]];}).flat();
const gloves={};for(const side of ['left','right']){
 const g=new THREE.Group();root.add(g);
 const joints=Array.from({length:21},(_,i)=>mesh(new THREE.SphereGeometry(i===0?.007:.0045,10,8),mat(colors[side],{emissive:colors[side],emissiveIntensity:.65}),g));
 const bones=new THREE.LineSegments(new THREE.BufferGeometry(),new THREE.LineBasicMaterial({color:colors[side]}));g.add(bones);
 gloves[side]={group:g,joints,bones};
}
const extras=new Map();
const M=a=>new THREE.Matrix4().fromArray(a.flat()).transpose();
const pos=a=>new THREE.Vector3(a[0][3],a[1][3],a[2][3]);
function put(object,a){object.visible=!!a;if(a)object.matrix.copy(M(a));}
function setLine(line,points){line.geometry.dispose();line.geometry=new THREE.BufferGeometry().setFromPoints(points);if(line.computeLineDistances)line.computeLineDistances();}
function transformView(p){return p.clone().applyMatrix4(root.matrix);}
function focus(view='orbit'){
 root.updateMatrixWorld(true);const points=[head,...Object.values(controllers)].filter(o=>o.group.visible).map(o=>o.group.getWorldPosition(new THREE.Vector3()));
 for(const side of ['left','right'])if(hands[side].group.visible)for(const joint of hands[side].joints)if(joint.visible)points.push(joint.getWorldPosition(new THREE.Vector3()));
 for(const side of ['left','right'])if(gloves[side].group.visible)for(const joint of gloves[side].joints)points.push(joint.getWorldPosition(new THREE.Vector3()));
 const box=new THREE.Box3();points.forEach(p=>box.expandByPoint(p));
 let target=new THREE.Vector3(0,mode==='world'?.9:-.25,0),radius=.6;
 if(points.length){box.getCenter(target);radius=Math.max(.42,box.getSize(new THREE.Vector3()).length()*.65);}
 const offset=view==='top'?new THREE.Vector3(.001,1,.001):view==='front'?new THREE.Vector3(0,.08,-1):new THREE.Vector3(.8,.48,-1);
 camera.position.copy(target).add(offset.normalize().multiplyScalar(radius*3.6));orbit.target.copy(target);orbit.update();
}
function updateScene(d){
 const live=!!d?.live, h=live?d.head:null, usableFrame=live&&(mode==='world'||!!h);
 root.matrix.identity();if(mode==='head'&&h)root.matrix.copy(M(h).invert());
 grid.position.y=mode==='head'?-.9:0;plane.position.y=grid.position.y-.005;
 put(head.group,h);head.axes.visible=$('axes').checked;head.dir.visible=$('axes').checked;
 const seq=d?.controllers?.sequence;
 const newSeq=seq!==lastSequence;lastSequence=seq;
 for(const side of ['left','right']){
  const c=d?.controllers?.[side],o=controllers[side],pose=usableFrame&&!d.controllers.stale?c?.pose_avp:null;
  put(o.group,pose);o.axes.visible=$('axes').checked;o.dir.visible=$('axes').checked;
  o.ray.visible=!!(pose&&h&&$('rays').checked);if(o.ray.visible)setLine(o.ray,[pos(h),pos(pose)]);
  if(pose&&newSeq){o.history.push(pos(pose));if(o.history.length>120)o.history.shift();setLine(o.trail,o.history);}
  if(!pose){o.history=[];setLine(o.trail,[]);}
  o.trail.visible=!!pose&&$('trails').checked;
  const b=c?.buttons||{},a=c?.axes||{};o.faceA.material.emissiveIntensity=b[side==='left'?'x':'a']?2:.15;o.faceB.material.emissiveIntensity=b[side==='left'?'y':'b']?2:.15;
  o.stick.rotation.z=-(a.thumbstick_x||0)*.5;o.stick.rotation.x=(a.thumbstick_y||0)*.5;o.trigger.material.emissiveIntensity=.15+(a.trigger||0)*2;
  const glove=d?.controllers?.gloves?.[side],gv=gloves[side];
  gv.group.visible=!!(usableFrame&&!d?.controllers?.stale&&glove?.valid&&$('gloves').checked);
  if(gv.group.visible){gv.joints.forEach((j,i)=>j.position.set(...glove.joints_avp[i]));setLine(gv.bones,GLOVE_EDGES.flatMap(e=>e.map(i=>new THREE.Vector3(...glove.joints_avp[i]))));}
  const hand=d?.hands?.[side],hv=hands[side];hv.group.visible=!!(usableFrame&&hand?.present&&$('hands').checked);
  if(hv.group.visible){hv.joints.forEach((j,i)=>{j.visible=i<hand.joints.length;if(j.visible)j.position.set(...hand.joints[i]);});setLine(hv.bones,EDGES.filter(e=>e[1]<hand.joints.length).flatMap(e=>e.map(i=>new THREE.Vector3(...hand.joints[i]))));}
 }
 const used=new Set();for(const ex of (d?.extras||[])){
  const id=ex.kind+ex.id;used.add(id);let g=extras.get(id);if(!g){g=new THREE.Group();g.matrixAutoUpdate=false;g.add(new THREE.AxesHelper(.12));mesh(new THREE.BoxGeometry(.05,.05,.004),mat(0xe69bf3,{wireframe:true}),g);root.add(g);extras.set(id,g);}put(g,usableFrame&&ex.tracked?ex.pose:null);
 }for(const [id,g]of extras)if(!used.has(id))g.visible=false;
 if(fitPending&&h){focus();fitPending=false;}
}
function updateUI(d){
 const live=d?.live&&performance.now()-lastArrival<650;
 $('source-ip').textContent=d?.ip||'Connecting…';
 const cal=d?.controllers?.calibration;
 $('alignment-title').textContent=cal?.preview?'Manual preview':cal?.reviewed_this_session?'Manual calibration':cal?.saved?'Review saved alignment':'Alignment unverified';
 $('alignment-detail').textContent=cal?'Native world + grip offsets applied. '+(cal.preview?'Adjustments are live; save or cancel in the headset.':'Recheck against physical controllers after restarting or recentering.'):'Controller LOCAL → ARKit uses identity. Calibrate from the headset startup panel. Meshes are schematic; hands may be cached.';
 $('live-pill').className='status-pill '+(frozen?'frozen':live?'live':'');$('live-text').textContent=frozen?'FROZEN':live?'LIVE STREAM':'NO LIVE DATA';
 $('notice').style.display=live||frozen?'none':'block';
 $('hz').textContent=live?fixed(d?.packet_hz,1):'—';$('age').textContent=frozen?'frozen':d?.age_ms==null?'— ms':Math.round(d.age_ms)+' ms';
 $('sequence').textContent=d?.controllers?.supported?`Controller seq ${d.controllers.sequence.toLocaleString()} · ${fixed(d.controller_hz,1)} updates/s`:'Waiting for controller packets';
 $('head-valid').textContent=d?.head?'POSE AVAILABLE':'NO POSE';
 const h=d?.head;$('head-xyz').innerHTML=['X','Y','Z'].map((x,i)=>`<span><small>${x} / m</small>${fmt(h?.[i]?.[3])}</span>`).join('');
 let joints=0;
 for(const side of ['left','right']){
  const c=d?.live&&!d?.controllers?.stale?d?.controllers?.[side]:null,pose=c?.pose_head,active=c?.active&&!d?.controllers?.stale&&d?.live;
  const badge=$(side+'-status');badge.className='badge '+(active&&c?.pose_valid?'valid':'');badge.textContent=!d?.live?'NO STREAM':d?.controllers?.stale?'STALE':!d?.controllers?.enabled?'DISABLED':active&&c?.pose_valid?'POSE + INPUT':active?'INPUT ONLY':'INACTIVE';
  $(side+'-xyz').innerHTML=['X','Y','Z'].map((x,i)=>`<span><small>${x}</small>${fmt(pose?.[i]?.[3])}</span>`).join('');
  const b=c?.buttons||{},a=c?.axes||{};
  for(const name of [side==='left'?'x':'a',side==='left'?'y':'b','menu','thumbstick']){const el=$(side+'-'+name);el.className='key '+(b[name]==null?'unavailable':b[name]?'pressed':'');}
  for(const name of ['trigger','grip']){$(side+'-'+name+'-value').textContent=a[name]==null?'—':fixed(a[name],3);$(side+'-'+name+'-bar').style.width=((a[name]||0)*100)+'%';}
  const dot=$(side+'-stick');dot.style.left=(50+(a.thumbstick_x||0)*38)+'%';dot.style.top=(50-(a.thumbstick_y||0)*38)+'%';dot.style.opacity=a.thumbstick_x==null?.2:1;dot.style.background=b.thumbstick?`var(--${side})`:'#122129';
  $(side+'-stick-xy').textContent=fmt(a.thumbstick_x,2)+' / '+fmt(a.thumbstick_y,2);
  $(side+'-distance').textContent=pose?'Head distance '+pos(pose).length().toFixed(3)+' m':c?.pose_status||'Pose unavailable';
  $(side+'-inputs').textContent=Object.values(c?.inputs||{}).filter(i=>i.active).length+'/8 inputs active';
  const hand=d?.hands?.[side];joints+=hand?.joints?.length||0;$(side+'-pinch').textContent=hand?.pinch_m==null?'—':(hand.pinch_m*100).toFixed(1)+' cm';
 }
 $('hand-count').textContent=joints+' joints';
 for(const side of ['left','right']){
  const g=d?.controllers?.gloves?.[side];
  $(side+'-glove').textContent=!d?.live?'No stream':g?.status||'Waiting for Wuji glove';
  $(side+'-glove').style.color=g?.valid?'var(--'+side+')':'var(--muted)';
 }

 const events=d?.events||[];$('events').innerHTML=events.length?events.slice(0,14).map(e=>`<div class="event"><time class="mono">${e.time}</time><b style="color:var(--${e.side})">${e.side[0].toUpperCase()}</b><span>${e.name.toUpperCase()}</span><span class="state">${e.pressed?'● pressed':'○ released'}</span></div>`).join(''):'<div class="empty">Press a controller button to inspect changes.</div>';
 if($('advanced').open)$('raw').textContent=JSON.stringify({head_world:d?.head,left_local:d?.controllers?.left.pose_local,left_head:d?.controllers?.left.pose_head,right_local:d?.controllers?.right.pose_local,right_head:d?.controllers?.right.pose_head,optional_channels:d?.extras,controller_timestamp_ns:d?.controllers?.timestamp_ns,alignment:d?.alignment,calibration:d?.controllers?.calibration,gloves:d?.controllers?.gloves,hand_validity:d?.hand_validity},null,2);
}
let renderCount=0,rateStart=performance.now();
function render(){requestAnimationFrame(render);orbit.update();scene.updateMatrixWorld(true);
 for(const [name,obj]of [['head',head],['left',controllers.left],['right',controllers.right]]){const label=$('label-'+name);const p=obj.group.getWorldPosition(new THREE.Vector3()).project(camera);label.style.display=obj.group.visible&&p.z>=-1&&p.z<=1&&Math.abs(p.x)<1.1&&Math.abs(p.y)<1.1?'block':'none';label.style.left=((p.x+1)*.5*canvas.clientWidth)+'px';label.style.top=((-p.y+1)*.5*canvas.clientHeight)+'px';}
 if(!frozen&&displayed&&performance.now()-lastArrival>650&&displayed.live){displayed={...displayed,live:false,head:null,hands:{},extras:[],controllers:{...displayed.controllers,stale:true}};updateScene(displayed);updateUI(displayed);}
 renderer.render(scene,camera);renderCount++;const now=performance.now();if(now-rateStart>1000){$('render-status').textContent=`${Math.round(renderCount*1000/(now-rateStart))} FPS · Y-UP · ${mode==='world'?'WORLD':'HEAD'} FRAME`;renderCount=0;rateStart=now;}}
new ResizeObserver(()=>{const r=$('viewport').getBoundingClientRect();renderer.setSize(r.width,r.height,false);camera.aspect=r.width/r.height;camera.updateProjectionMatrix();}).observe($('viewport'));
function applyFrame(d){displayed=d;updateScene(d);updateUI(d);hasFrame=true;}
const stream=new EventSource('/events');stream.onmessage=e=>{try{latest=JSON.parse(e.data);lastArrival=performance.now();if(!frozen)applyFrame(latest);}catch(err){console.error(err);$('render-status').textContent='Frame decode failed';}};
stream.onerror=()=>{if(!frozen){$('live-text').textContent='RECONNECTING';$('live-pill').className='status-pill';}};
$('pause').onclick=()=>{frozen=!frozen;$('pause').textContent=frozen?'▶ Resume':'Ⅱ Freeze';$('pause').classList.toggle('active',frozen);if(!frozen&&latest)applyFrame(latest);else updateUI(displayed);};
for(const [id,value]of [['world','world'],['head-frame','head']])$(id).onclick=()=>{mode=value;$('world').classList.toggle('active',mode==='world');$('head-frame').classList.toggle('active',mode==='head');$('frame-caption').textContent=mode==='world'?'ARKIT WORLD / METERS':'CURRENT HEAD FRAME / METERS';$('view-sub').textContent=mode==='world'?'Reference grid · 25 cm divisions':'Head at origin · reference grid follows head axes';fitPending=true;if(displayed)updateScene(displayed);};
for(const id of ['hands','gloves','trails','axes','rays'])$(id).onchange=()=>{if(displayed)updateScene(displayed);};
$('fit').onclick=()=>focus();$('front').onclick=()=>focus('front');$('top').onclick=()=>focus('top');
$('snapshot').onclick=()=>{if(!displayed)return;const data={saved_at:new Date().toISOString(),view:mode,frozen,...displayed};const url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='visionpro-frame-'+Date.now()+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
window.addEventListener('keydown',e=>{if(e.code==='Space'&&e.target===document.body){e.preventDefault();$('pause').click();}});
updateScene(null);updateUI(null);render();
