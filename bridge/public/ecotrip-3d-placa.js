//  ecotrip-3d-placa.js — desenha a placa Mercosul no carro 3D.
//
//  Por que isto cria GEOMETRIA em vez de trocar textura: a carroceria que o viewer
//  carrega (`haval-h6-hev-lite.glb`, usada também pelos trims PHEV) NÃO tem malha
//  de placa — 173 nós, nenhum. Existem malhas `11_licence_map_*` no
//  `H6-2026-PHEV_3.glb`, mas esse arquivo o viewer não carrega. Então a placa é um
//  plano novo, posicionado a partir da bounding box do carro.
//
//  A posição não dá pra conferir daqui: renderização headless não desenha. Por isso
//  todo o posicionamento é ajustável por query string, pra corrigir no olho sem
//  redeploy:
//    ?placa=TFG4H72     texto (7 chars Mercosul, sem hífen)
//    &placaY=0.52       altura em metros
//    &placaZ=0          recuo/avanço extra em metros (+ pra fora do carro)
//    &placaW=0.40       largura em metros (padrão brasileiro: 0,40 × 0,13)
//    &placaDebug=1      loga a caixa do carro e as posições escolhidas
(function () {
  'use strict';

  function param(n, d) {
    try {
      var q = new URLSearchParams(location.search.replace(/^\?/, ''));
      var h = new URLSearchParams(location.hash.replace(/^#/, ''));
      var v = q.get(n) || h.get(n);
      return (v === null || v === '') ? d : v;
    } catch (e) { return d; }
  }

  var TEXTO = String(window.__ECOTRIP_PLATE__ || param('placa', '')).toUpperCase()
                .replace(/[^A-Z0-9]/g, '');       // hífen é como se escreve, não como se estampa
  if (!TEXTO) return;                              // sem placa configurada, não mexe no carro

  var DEBUG = param('placaDebug', '') === '1';
  var LARG  = parseFloat(param('placaW', '0.40'));  // 400 mm — padrão brasileiro
  var ALT   = LARG * (130 / 400);                   // 130 mm, proporção travada
  var YOFF  = parseFloat(param('placaY', '0.52'));
  var ZOFF  = parseFloat(param('placaZ', '0'));

  /** Desenha a placa Mercosul num canvas. Proporção 400×130 mm.
   *
   *  A fonte oficial é a FE-Schrift (a mesma alemã, adotada no Mercosul), que não
   *  existe no iOS. Uso uma condensada pesada: a leitura fica correta, o desenho
   *  das letras não é idêntico ao da placa real. Trocar exigiria embutir a fonte,
   *  que é licenciada. */
  function desenha() {
    var S = 8;                                       // 8 px por mm → 3200×1040
    var W = 400 * S, H = 130 * S;
    var c = document.createElement('canvas');
    c.width = W; c.height = H;
    var g = c.getContext('2d');

    // Corpo branco com a borda preta do padrão
    g.fillStyle = '#ffffff'; g.fillRect(0, 0, W, H);
    var faixaH = Math.round(H * 0.175);              // tarja azul superior

    // Tarja azul: BRASIL ao centro, Mercosul à esquerda, BR à direita
    g.fillStyle = '#003399'; g.fillRect(0, 0, W, faixaH);
    g.fillStyle = '#ffffff';
    g.textBaseline = 'middle';
    g.font = 'bold ' + Math.round(faixaH * 0.62) + 'px "Helvetica Neue", Arial, sans-serif';
    g.textAlign = 'center';
    g.fillText('BRASIL', W / 2, faixaH * 0.54);
    g.textAlign = 'right';
    g.font = 'bold ' + Math.round(faixaH * 0.58) + 'px "Helvetica Neue", Arial, sans-serif';
    g.fillText('BR', W - faixaH * 0.35, faixaH * 0.54);
    // Bandeira simplificada à esquerda (verde/amarelo): a real é um losango com
    // esfera; nesta escala, na tela, o que se lê é a mancha de cor.
    var bw = faixaH * 1.15, bh = faixaH * 0.52, bx = faixaH * 0.3, by = faixaH * 0.24;
    g.fillStyle = '#009c3b'; g.fillRect(bx, by, bw, bh);
    g.fillStyle = '#ffdf00';
    g.beginPath();
    g.moveTo(bx + bw / 2, by + 3); g.lineTo(bx + bw - 5, by + bh / 2);
    g.lineTo(bx + bw / 2, by + bh - 3); g.lineTo(bx + 5, by + bh / 2);
    g.closePath(); g.fill();

    // Moldura preta
    g.strokeStyle = '#111111'; g.lineWidth = Math.round(S * 1.6);
    g.strokeRect(g.lineWidth / 2, g.lineWidth / 2, W - g.lineWidth, H - g.lineWidth);

    // Caracteres: 7 no padrão Mercosul (LLLNLNN), sem hífen e sem separação extra
    g.fillStyle = '#111111';
    g.textAlign = 'center';
    var areaY = faixaH + (H - faixaH) / 2;
    var tam = Math.round((H - faixaH) * 0.78);
    g.font = 'bold ' + tam + 'px "Helvetica Neue Condensed Bold", "Arial Narrow", Arial, sans-serif';
    // Espaçamento uniforme calculado na largura útil — centralizar a string inteira
    // deixaria o miolo apertado em fontes com avanços diferentes por caractere.
    var util = W * 0.86, x0 = (W - util) / 2, n = TEXTO.length;
    for (var i = 0; i < n; i++) {
      g.fillText(TEXTO[i], x0 + util * ((i + 0.5) / n), areaY + tam * 0.04);
    }
    return c;
  }

  // Com ?placaDebug=1 a arte aparece sobreposta no canto: dá pra conferir o desenho
  // sem depender da cena 3D ter carregado — e é como eu valido isto sem GPU aqui.
  if (DEBUG) {
    try {
      var cv = desenha();
      cv.style.cssText = 'position:fixed;left:8px;bottom:8px;width:320px;z-index:99999;'
                       + 'border:1px solid #0af;background:#fff';
      cv.id = '__placa_preview';
      (document.body || document.documentElement).appendChild(cv);
    } catch (e) {}
  }

  function instala(scene, THREE) {
    if (scene.getObjectByName('__ecotrip_placa_f')) return true;   // já posta
    // A caixa do CARRO, não da cena: a cena tem chão, luzes e helpers, e incluir
    // isso jogaria a placa pra fora do veículo.
    var carro = null;
    scene.traverse(function (o) {
      if (carro) return;
      if (o.isObject3D && /car|body|haval|root/i.test(o.name || '') && o.children.length > 4) carro = o;
    });
    var alvo = carro || scene;
    var box = new THREE.Box3().setFromObject(alvo);
    if (!isFinite(box.min.x) || box.isEmpty()) return false;

    var tex = new THREE.CanvasTexture(desenha());
    if ('SRGBColorSpace' in THREE) tex.colorSpace = THREE.SRGBColorSpace;
    tex.anisotropy = 8;
    var mat = new THREE.MeshBasicMaterial({ map: tex, transparent: false });
    var geo = new THREE.PlaneGeometry(LARG, ALT);

    var cx = (box.min.x + box.max.x) / 2;
    var y  = box.min.y + YOFF;
    // O eixo do comprimento é o maior lado horizontal — não assumo que é Z, porque
    // GLB exportado de Blender costuma vir com a frente em +X ou −Z conforme o rig.
    var dx = box.max.x - box.min.x, dz = box.max.z - box.min.z;
    var comprZ = dz >= dx;
    var frente = new THREE.Mesh(geo, mat), tras = new THREE.Mesh(geo, mat);
    frente.name = '__ecotrip_placa_f'; tras.name = '__ecotrip_placa_t';
    if (comprZ) {
      frente.position.set(cx, y, box.max.z + 0.01 + ZOFF);
      tras.position.set(cx, y, box.min.z - 0.01 - ZOFF);
      tras.rotation.y = Math.PI;
    } else {
      frente.position.set(box.max.x + 0.01 + ZOFF, y, (box.min.z + box.max.z) / 2);
      frente.rotation.y = Math.PI / 2;
      tras.position.set(box.min.x - 0.01 - ZOFF, y, (box.min.z + box.max.z) / 2);
      tras.rotation.y = -Math.PI / 2;
    }
    scene.add(frente); scene.add(tras);
    if (DEBUG) {
      console.log('[placa]', TEXTO, 'caixa', JSON.stringify(box), 'comprEmZ', comprZ,
                  'frente', JSON.stringify(frente.position));
    }
    return true;
  }

  // O modelo entra na cena depois do boot e pode ser trocado (trim/variante), então
  // tenta por um tempo e mantém uma verificação rala pra repor se a placa sumir.
  var tentativas = 0;
  var t = setInterval(function () {
    try {
      var app = window.__app, THREE = window.THREE;
      if (app && app.scene && THREE && instala(app.scene, THREE)) {
        clearInterval(t);
        setInterval(function () {
          try { if (window.__app && window.__app.scene) instala(window.__app.scene, window.THREE); }
          catch (e) {}
        }, 5000);
      }
    } catch (e) {}
    if (++tentativas > 120) clearInterval(t);   // ~2 min e desiste, sem travar a página
  }, 1000);
})();
