"""Cascata de produção: temas, menu 270px, controles e limites responsivos."""
from pathlib import Path
import re,sys
sys.path.insert(0,'/tmp/cde-css-libs')
import tinycss2,cssselect2
from lxml import html
base=Path(__file__).resolve().parents[1]
css='\n'.join((base/f).read_text() for f in ['assets/desempenho.css','modelo.css','assets/cde-design-tokens.css','assets/pdi-visual.css','assets/logistica-visual.css','assets/botoes-cde.css'])
fixture='''<div class="logistics"><section class="card" id="card"><button class="button primary" id="log-save">Registrar</button><button class="button secondary" id="log-edit">Ajustes</button><button class="button danger log-delete-x" id="log-delete">×</button><form class="management-actions fuel-month-controls" id="month-controls"><div class="field fuel-month-field"><input type="month" id="month-input"></div><button class="button secondary">Consultar</button></form></section><div class="stats-grid" id="kpis"></div><details class="performance-export"><button class="button secondary" id="log-export">CSV</button></details></div><section class="performance-modules"><button class="button secondary performance-module-action" id="module-open">Abrir Logística</button></section>'''
fixture+='<button class="button primary" id="general-action">Criar nova meta</button><button class="button secondary" id="general-edit">Editar</button><button class="button danger" id="general-delete">Excluir</button>'
rules=tinycss2.parse_stylesheet(css,skip_comments=True,skip_whitespace=True)
# Carrega apenas o avaliador da bateria anterior, sem executar seus contratos de outro HTML.
source=r'''def syntax(rs):
 for r in rs:
  assert r.type!='error',r
  if r.type=='at-rule'and r.content:syntax(tinycss2.parse_rule_list(r.content,skip_comments=True,skip_whitespace=True))
  if r.type=='qualified-rule':assert not[d for d in tinycss2.parse_declaration_list(r.content,skip_comments=True,skip_whitespace=True)if d.type=='error']
syntax(rules)
def styles(theme,width,height,opened=False):
 doc=html.fromstring((base/'index.html').read_text());doc.set('data-theme',theme)
 if opened:
  doc.get_element_by_id('sidebar').set('class','sidebar is-open');doc.get_element_by_id('mobile-menu').set('aria-expanded','true')
 matcher=cssselect2.Matcher()
 def add(rs):
  for r in rs:
   if r.type=='at-rule'and r.lower_at_keyword=='media':
    query=tinycss2.serialize(r.prelude)
    if 'prefers-reduced-motion'in query:continue
    valid=True
    for mode,axis,n in re.findall(r'(min|max)-(width|height):\s*(\d+)px',query):
     value=width if axis=='width'else height;valid&=value>=int(n)if mode=='min'else value<=int(n)
    if valid:add(tinycss2.parse_rule_list(r.content,skip_comments=True,skip_whitespace=True))
   if r.type=='at-rule'and r.lower_at_keyword=='supports'and r.content:add(tinycss2.parse_rule_list(r.content,skip_comments=True,skip_whitespace=True))
   if r.type!='qualified-rule':continue
   try:ss=cssselect2.compile_selector_list(tinycss2.serialize(r.prelude))
   except cssselect2.SelectorError:continue
   declarations=[(d.lower_name,tinycss2.serialize(d.value).strip(),d.important)for d in tinycss2.parse_declaration_list(r.content,skip_comments=True,skip_whitespace=True)if d.type=='declaration']
   for selector in ss:matcher.add_selector(selector,declarations)
 add(rules);result={};inherited={}
 for node in cssselect2.ElementWrapper.from_html_root(doc).iter_subtree():
  vals={};ranks={};variables=dict(inherited.get(node.parent,{}))
  for specificity,order,pseudo,ds in matcher.match(node):
   if pseudo:continue
   for k,v,important in ds:
    rank=(important,specificity,order)
    if k not in ranks or rank>=ranks[k]:ranks[k]=rank;vals[k]=v
  variables.update({k:v for k,v in vals.items()if k.startswith('--')});inherited[node]=variables
  def resolve(v):
   for _ in range(10):
    value=re.sub(r'var\((--[\w-]+)\)',lambda m:variables.get(m[1],m[0]),v)
    if value==v:return value
    v=value
   return v
  if node.id:result[node.id]={k:resolve(v)for k,v in vals.items()}
  if 'brand'in node.classes:result['brand']={k:resolve(v)for k,v in vals.items()}
 return result
def contrast(a,b):
 def luminance(v):
  if len(v)==4:v='#'+''.join(c*2 for c in v[1:])
  rgb=[int(v[i:i+2],16)/255 for i in(1,3,5)];x=[n/12.92 if n<=.04045 else((n+.055)/1.055)**2.4 for n in rgb];return sum(n*w for n,w in zip(x,[.2126,.7152,.0722]))
 x,y=sorted([luminance(a),luminance(b)]);return(y+.05)/(x+.05)
'''
source=source.replace("doc.set('data-theme',theme)","doc.set('data-theme',theme);doc.get_element_by_id('app-screen').attrib.pop('hidden',None);doc.find('body').set('class','signed-in'+(' menu-open' if opened else ''));doc.get_element_by_id('page-content').append(html.fromstring(fixture));doc.get_element_by_id('page-performance').append(html.fromstring('<div class=\"pdi-perf\"><button id=\"pcp-save\">Registrar</button><button class=\"pdi-perf-secondary\" id=\"pcp-edit\">Ajustar</button><div class=\"performance-export\"><button class=\"button secondary\" id=\"pcp-export\">CSV</button></div></div>'))")
source=source.replace("doc.get_element_by_id('sidebar').set('class','sidebar is-open');doc.get_element_by_id('mobile-menu').set('aria-expanded','true')","doc.get_element_by_id('menu-toggle').set('aria-expanded','true')")
exec(source)
checks=0
for theme in ['light','dark']:
 for width in [320,390,480,600,700,768,900,960,961,1024,1200,1201,1440,1600,1920]:
  for height in [500,900]:
   s=styles(theme,width,height)
   assert s['app-sidebar']['width']==('calc(100vw - 24px)' if width<=480 else 'min(360px,calc(100vw - 32px))' if width<=960 else '270px');checks+=1
   assert s['menu-toggle']['display']==('flex' if width<=960 else 'none');checks+=1
   for id in ['general-action','general-edit','general-delete','log-save','log-edit','log-delete','module-open','pcp-save','pcp-edit']:
    assert s[id]['background']==('#1d3d5d' if theme=='light' else '#315573'),(id,theme,s[id]['background'])
    assert s[id]['border']=='0';assert contrast(s[id]['color'],s[id]['background'])>=4.5;assert s[id]['color']in('#fff','white');assert s[id]['min-height']=='44px';checks+=4
   for id in ['modal-close','password-toggle']:
    assert s[id]['background']==('#edf2f7' if theme=='light' else '#263447');assert contrast(s[id]['color'],s[id]['background'])>=4.5;checks+=2
   for id in ['log-export','pcp-export']:assert s[id]['background']=='transparent';assert s[id]['min-height']=='36px';checks+=2
   assert s['log-delete']['width']==s['log-delete']['height']=='44px';checks+=1
   assert s['card']['background']==('#fff' if theme=='light' else '#1a222e');checks+=1
   assert s['month-input']['min-height']=='44px';checks+=1
   assert s['month-controls']['grid-template-columns']==('minmax(0,1fr)' if width<=600 else 'minmax(0,240px) auto');checks+=1
   if width<=960:
    opened=styles(theme,width,height,True)
    assert s['app-sidebar']['visibility']=='hidden' and opened['app-sidebar']['visibility']=='visible';checks+=1
    for k in ['width','height','border','background','padding']:assert s['menu-toggle'][k]==opened['menu-toggle'][k];checks+=1
    assert s['menu-toggle']['width']=='132px' and s['menu-toggle']['height']=='56px';checks+=1
    assert s['menu-toggle']['border']=='3px solid transparent';checks+=1
print(f'{checks} verificações CSS de produção em 60 cenários: menu 270px, Menu/Fechar, temas, botões de todos os módulos, CSV discreto e seletor de mês: OK. Sem renderização em navegador.')
