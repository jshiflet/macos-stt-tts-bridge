let ws, mediaStream;
const log = (m)=>{const el=document.getElementById('sttOut'); el.textContent+=m+"\n"; el.scrollTop=el.scrollHeight;};
const start = async ()=>{
  document.getElementById('sttOut').textContent='';
  const lang = document.getElementById('lang').value || 'en-US';
  const offline = document.getElementById('offline').checked;
  const partials = document.getElementById('partials').checked;
  mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const audioCtx = new AudioContext({ sampleRate: 16000 });
  const source = audioCtx.createMediaStreamSource(mediaStream);
  const proc = audioCtx.createScriptProcessor(4096,1,1);
  source.connect(proc); proc.connect(audioCtx.destination);
  ws = new WebSocket(`ws://${location.host}/stt/stream?lang=${encodeURIComponent(lang)}&offline=${offline}&partials=${partials}`);
  ws.onopen = ()=>log('WS connected');
  ws.onmessage = ev=>{ try{ const o=JSON.parse(ev.data);
    if(o.type==='partial') log('· '+o.text);
    if(o.type==='final') log('✔ '+o.text+(o.confidence!=null?` (conf=${o.confidence.toFixed(2)})`:''));
    if(o.type==='error') log('⚠ Error: '+o.error);
  }catch{} };
  ws.onclose = ()=>log('WS closed');
  proc.onaudioprocess = e=>{
    if(!ws || ws.readyState!==1) return;
    const input=e.inputBuffer.getChannelData(0);
    const buf=new ArrayBuffer(input.length*2), view=new DataView(buf);
    for(let i=0;i<input.length;i++){ let s=Math.max(-1,Math.min(1,input[i])); view.setInt16(i*2, s<0?s*0x8000:s*0x7FFF, true); }
    ws.send(buf);
  };
  document.getElementById('startBtn').disabled=true;
  document.getElementById('stopBtn').disabled=false;
};
const stop = ()=>{
  if(ws) ws.close();
  if(mediaStream) mediaStream.getTracks().forEach(t=>t.stop());
  document.getElementById('startBtn').disabled=false;
  document.getElementById('stopBtn').disabled=true;
};
document.getElementById('startBtn').onclick=start;
document.getElementById('stopBtn').onclick=stop;

const initVoices = async () => {
  try {
    const res = await fetch('/voices');
    const voices = await res.json();
    const sel = document.getElementById('voiceId');
    voices
      .sort((a, b) => a.name.localeCompare(b.name))
      .forEach(v => {
        const opt = document.createElement('option');
        opt.value = v.identifier;
        opt.textContent = `${v.name} (${v.language}) - ${v.quality === 2 ? 'Enhanced' : 'Default'}`;
        if (v.name === 'Anna' && v.quality === 2) {
          opt.selected = true;
        }
        sel.appendChild(opt);
      });
  } catch (e) {
    console.error('Failed to load voices', e);
  }
};

document.getElementById('ttsBtn').onclick=async()=>{
  const text=document.getElementById('ttsText').value;
  const voiceId=document.getElementById('voiceId').value || null;
  const rate=parseFloat(document.getElementById('rate').value);
  const pitch=parseFloat(document.getElementById('pitch').value);
  const speakLocal=document.getElementById('speakLocal').checked;
  const res=await fetch('/tts',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text,voiceId,rate,pitch,speakLocal})});
  if(speakLocal){ await res.json(); alert('Local playback started.'); return; }
  const blob=await res.blob(); const url=URL.createObjectURL(blob); const player=document.getElementById('player'); player.src=url; player.play();
};

window.onload = initVoices;
