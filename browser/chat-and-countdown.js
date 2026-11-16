(() => {
  const config=window.STREAM_CONFIG,mode=document.body.dataset.mode;
  const root=document.querySelector('#widget'),preview=new URLSearchParams(location.search).get('preview')==='1';
  document.body.style.setProperty('--accent',config.brand.accent);
  const el=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;};
  if(mode==='countdown'){
    const box=el('div',undefined,'clock-wrap'),clock=el('div','','countdown');box.append(clock);root.append(box);
    const until=Date.now()+config.startingMinutes*60000;
    const tick=()=>{const n=preview?config.startingMinutes*60:Math.max(0,Math.ceil((until-Date.now())/1000));clock.textContent=`${String(Math.floor(n/60)).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`;};tick();setInterval(tick,250);return;
  }
  if(mode!=='chat')return;
  const feed=el('div',undefined,'chat-feed');root.append(feed);let notice;
  const tell=(text)=>{if(notice)notice.remove();notice=el('div',text,'chat-notice');feed.append(notice);};
  const add=(name,body,tags={})=>{
    if(notice){notice.remove();notice=null;}
    const n=el('div',undefined,'message');n.dataset.id=tags.id||'';n.dataset.userId=tags['user-id']||'';n.dataset.user=name.toLowerCase();n.dataset.created=String(Date.now());
    const badges=(tags.badges||'').split(',').map(x=>x.split('/')[0]);const role=badges.includes('broadcaster')?'HOST':badges.includes('moderator')?'MOD':badges.includes('vip')?'VIP':'';
    if(role)n.append(el('span',role,'badge'));n.append(el('span',name,'name'));if(body.startsWith('\u0001ACTION'))n.classList.add('action');n.append(el('span',body.replace(/^\u0001ACTION /,'').replace(/\u0001$/,'')));feed.append(n);
    while(feed.querySelectorAll('.message').length>config.chat.maxMessages)feed.querySelector('.message').remove();
    while(feed.scrollHeight>feed.clientHeight&&feed.querySelectorAll('.message').length>1)feed.querySelector('.message').remove();
  };
  if(preview){add('cozycoder','late-night queue? I’m in.');add('itzmaniss','pull up a seat 🫶',{badges:'broadcaster/1'});add('pixelpal','games, good vibes, questionable aim.');return;}
  let socket,retry=0,buffer='',timer;
  function connect(){
    clearTimeout(timer);buffer='';socket=new WebSocket('wss://irc-ws.chat.twitch.tv:443');
    socket.onopen=()=>{socket.send('CAP REQ :twitch.tv/tags twitch.tv/commands\r\n');socket.send(`NICK justinfan${100000+Math.floor(Math.random()*900000)}\r\n`);socket.send(`JOIN #${config.brand.twitchChannel.toLowerCase()}\r\n`);};
    socket.onmessage=e=>{buffer+=String(e.data);const lines=buffer.split('\r\n');buffer=lines.pop();for(const line of lines){const m=window.StreamIrc.parseIrc(line);if(!m)continue;
      if(m.command==='PING'){socket.send(`PONG :${m.body||m.params.join(' ')}\r\n`);continue;}
      if(m.command==='366'||m.command==='ROOMSTATE'){retry=0;if(notice){notice.remove();notice=null;}}
      if(m.command==='RECONNECT')socket.close();
      if(m.command==='PRIVMSG')add(m.tags['display-name']||m.prefix.split('!')[0],m.body,m.tags);
      if(m.command==='CLEARMSG'){for(const n of feed.querySelectorAll('.message'))if(n.dataset.id===m.tags['target-msg-id'])n.remove();}
      if(m.command==='CLEARCHAT'){for(const n of feed.querySelectorAll('.message'))if(!m.body||n.dataset.user===m.body.toLowerCase()||n.dataset.userId===m.tags['target-user-id'])n.remove();}
      if(m.command==='NOTICE'&&/authentication|login/i.test(m.body))tell('Chat connection unavailable.');
    }};
    socket.onerror=()=>{};socket.onclose=()=>{tell('Chat reconnecting…');timer=setTimeout(connect,Math.min(30000,1500*2**Math.min(retry++,5)));};
  }
  connect();
  setInterval(()=>{if(!config.chat.fadeAfterSeconds)return;for(const n of feed.querySelectorAll('.message'))if(Date.now()-Number(n.dataset.created)>config.chat.fadeAfterSeconds*1000){n.classList.add('expiring');setTimeout(()=>n.remove(),1000);}},2000);
  window.addEventListener('beforeunload',()=>{clearTimeout(timer);if(socket){socket.onclose=null;socket.close();}});
})();
