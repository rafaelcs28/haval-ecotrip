#!/usr/bin/env node
// Teste de regressão da tela de parede. Roda o Chrome que já existe no Mac em vez
// de puxar o Playwright (~300MB de browsers) — o que se precisa aqui é carregar a
// página, deixar o JS rodar e afirmar sobre o DOM final.
//
// Usa o `?demo=` pra exercitar os estados que a realidade quase nunca mostra:
// crítico, sem-leitura, usina parcial. Antes disso a parede só tinha sido vista
// com tudo verde, e os dois primeiros bugs achados assim eram de layout.
import { writeFileSync, unlinkSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = dirname(fileURLToPath(import.meta.url));
const PUB = join(AQUI, '..', 'public');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORTA = process.env.PORT || 3000;
const TOKEN = process.env.WALL_TEST_TOKEN
  || (readFileSync(join(AQUI, '..', '.env'), 'utf8').match(/^BRIDGE_TOKEN_HASH=(.+)$/m) || [])[1];
if (!TOKEN) { console.error('sem token: defina WALL_TEST_TOKEN ou BRIDGE_TOKEN_HASH no .env'); process.exit(2); }

// As afirmações rodam DENTRO da página; o resultado sai por document.title, que é
// o que o --dump-dom traz de volta sem precisar de protocolo de depuração.
const SONDA = (cenario, retrato) => `
  const erros = [];
  const t = (nome, cond) => { if (!cond) erros.push(nome); };
  const txt = (sel) => (document.querySelector(sel)?.textContent || '').trim();
  const corpo = document.body;
  const cen = ${JSON.stringify(cenario)};
  const retrato = ${JSON.stringify(!!retrato)};

  t('pintou alguma usina', document.querySelectorAll('.plant[data-usina]').length >= 3);
  t('nucleo tem veredito', /TUDO OK|ATENÇÃO|CRÍTICO/.test(txt('#hubstate')));
  t('titulo responde se precisa agir', /Nada a fazer|Vale olhar|Precisa de você/.test(txt('#vnum')));
  t('lista de servicos cheia', document.querySelectorAll('#side .srow').length >= 8);
  t('grafico de hoje desenhou', document.querySelectorAll('#spark rect').length > 0);
  t('grafico de 30 dias desenhou', document.querySelectorAll('#daily rect').length > 0);

  // O bug que o modo demo achou: coluna empurrava card pra fora da tela.
  // Em retrato a página rola de propósito, então a checagem não se aplica.
  if (!retrato) for (const c of document.querySelectorAll('.colL,.colC,.colR')) {
    t('coluna ' + c.className + ' dentro da tela',
      c.getBoundingClientRect().bottom <= innerHeight + 2);
  }
  if (retrato) {
    // Três defeitos seguidos apareceram só no celular: rodapé serrilhado,
    // cabeçalho sob a Dynamic Island e coluna cortada. Estas travam os três.
    const topo = document.querySelector('.top');
    t('cabecalho existe', !!topo);
    scrollTo(0, 800);
    const r = topo.getBoundingClientRect();
    t('cabecalho continua no topo depois de rolar', r.top >= -1 && r.bottom > r.top);
    t('cabecalho fica ACIMA do conteudo', getComputedStyle(topo).position === 'sticky');
    // Rodapé em colunas: os kW das usinas têm que compartilhar a mesma coluna.
    const kws = [...document.querySelectorAll('.plant .kw')].map(e => Math.round(e.getBoundingClientRect().right));
    t('valores das usinas alinhados na mesma coluna', new Set(kws).size <= 2);
    scrollTo(0, 0);
  }
  t('pagina nao rola na horizontal', document.documentElement.scrollWidth <= innerWidth + 2);

  if (cen === 'crit') {
    t('estado critico no body', corpo.dataset.state === 'crit');
    t('nucleo diz CRITICO', txt('#hubstate') === 'CRÍTICO');
    t('titulo pede acao', txt('#vnum') === 'Precisa de você');
    t('alertas listados', document.querySelectorAll('.vitem').length > 0);
    t('algum no acendeu', [...document.querySelectorAll('.nd')].some(n => n.dataset.sev === 'crit'));
  }
  if (cen === 'sem-leitura') {
    t('usina sem leitura nao vira zero',
      [...document.querySelectorAll('.plant .kw')].some(e => e.dataset.vazio === 'true'));
    t('soma parcial se declara', /\\d+ de \\d+ inversores/.test(txt('.foot')));
    t('total avisa que esta incompleto', /de \\d+ usinas completas/.test(txt('.foot')));
    t('estacao sem comunicacao aparece', /sem comunicação/.test(txt('#gauges')));
  }
  if (cen === 'ok') {
    t('sem alerta quando esta tudo bem', document.querySelectorAll('.vitem').length === 0);
    // Hover dos eventos: EM CIMA da linha detalha ela; NO VAO entre duas linhas
    // nao mostra nada. O vao escorregava pro container e despejava o log inteiro.
    const linhas = document.querySelectorAll('#evts .ev[data-evi]');
    const tip = document.getElementById('tip');
    if (linhas.length > 1) {
      const disp = (x, y) => {
        const el = document.elementFromPoint(x, y) || document.getElementById('evts');
        el.dispatchEvent(new MouseEvent('mousemove', { clientX: x, clientY: y, bubbles: true }));
      };
      const a = linhas[0].getBoundingClientRect(), b = linhas[1].getBoundingClientRect();
      disp(a.left + 30, a.top + a.height / 2);
      t('hover na linha de evento mostra detalhe', !tip.hidden);
      disp(a.left + 30, (a.bottom + b.top) / 2);
      t('hover no vao entre linhas nao abre o log inteiro', tip.hidden);
      disp(-10, -10);
    }
    t('nenhum no aceso', [...document.querySelectorAll('.nd')].every(n => !n.dataset.sev || n.dataset.sev === 'ok'));
  }
  document.title = erros.length ? 'FALHOU::' + erros.join(' | ') : 'OK';
`;

function roda(cenario, retrato = false) {
  return new Promise((resolve) => {
    const suf = retrato ? '_p' : '';
    const [LG, AL] = retrato ? [430, 932] : [1920, 1080];
    const arq = join(PUB, `_t_${cenario}${suf}.html`);
    const url = `/wall.html?demo=${cenario}`;   // 'ok' também é sintético: teste não pode depender do dia
    writeFileSync(arq, `<style>html,body{margin:0}iframe{border:0}</style>
<script>localStorage.setItem('bridge_token',${JSON.stringify(TOKEN)});
document.write('<iframe id="f" width="${LG}" height="${AL}" src="${url}"></iframe>');</script>
<script>
let n=0; const iv=setInterval(()=>{ n++;
  try{ const d=document.getElementById('f').contentDocument, w=document.getElementById('f').contentWindow;
    if(d && d.querySelectorAll('.plant[data-usina]').length>=3 && n>8){
      const fn=new w.Function(${JSON.stringify(SONDA(cenario, retrato))}); fn.call(w);
      document.title=d.title; clearInterval(iv); } }catch(e){}
  if(n>70){ document.title='FALHOU::a pagina nao terminou de desenhar'; clearInterval(iv); }
},250);
</script>`);
    const p = spawn(CHROME, ['--headless', '--disable-gpu', '--hide-scrollbars',
      '--virtual-time-budget=22000', `--window-size=${LG + 40},${AL + 40}`, '--dump-dom',
      `http://127.0.0.1:${PORTA}/_t_${cenario}${suf}.html`], { stdio: ['ignore', 'pipe', 'ignore'] });
    let saida = '';
    p.stdout.on('data', (d) => { saida += d; });
    p.on('close', () => {
      try { unlinkSync(arq); } catch {}
      const m = saida.match(/<title>([^<]*)<\/title>/);
      resolve({ cenario: cenario + (retrato ? ' (retrato)' : ''),
                titulo: m ? m[1] : '(sem resposta do navegador)' });
    });
  });
}

const cenarios = process.argv.slice(2).length ? process.argv.slice(2) : ['ok', 'crit', 'sem-leitura'];
// Paisagem (TV/monitor) e retrato (iPhone/iPad) são layouts diferentes de
// verdade, com defeitos próprios — rodar só um deixa o outro descoberto.
const execucoes = [...cenarios.map(c => [c, false]), ['ok', true], ['sem-leitura', true]];
let falhou = 0;
for (const [c, retrato] of execucoes) {
  const r = await roda(c, retrato);
  const ok = r.titulo === 'OK';
  if (!ok) falhou++;
  console.log(`${ok ? '  ok  ' : '  FALHA'}  ${r.cenario.padEnd(22)} ${ok ? '' : r.titulo.replace('FALHOU::', '')}`);
}
console.log(falhou ? `\n${falhou} cenário(s) com falha` : '\ntodos os cenários passaram');
process.exit(falhou ? 1 : 0);
