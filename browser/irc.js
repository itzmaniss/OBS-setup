// Pure parser, shared by the browser widget and protocol tests.
(function (scope) {
  function unescapeTag(value) { return value.replace(/\\([s:nr\\])/g, (_, c) => ({s:' ', ':':';', n:'\n', r:'\r', '\\':'\\'}[c])); }
  function parseIrc(line) {
    const tags={}; let rest=line, prefix='';
    if(rest.startsWith('@')) {const end=rest.indexOf(' ');if(end<0)return null;for(const t of rest.slice(1,end).split(';')){const pos=t.indexOf('=');tags[pos<0?t:t.slice(0,pos)]=unescapeTag(pos<0?'':t.slice(pos+1));}rest=rest.slice(end+1);}
    if(rest.startsWith(':')) {const end=rest.indexOf(' ');if(end<0)return null;prefix=rest.slice(1,end);rest=rest.slice(end+1);}
    const tail=rest.indexOf(' :');const body=tail>=0?rest.slice(tail+2):'';const head=(tail>=0?rest.slice(0,tail):rest).split(' ').filter(Boolean);
    if(!head[0])return null;return {tags,prefix,command:head[0],params:head.slice(1),body};
  }
  scope.StreamIrc={parseIrc};
})(globalThis);
