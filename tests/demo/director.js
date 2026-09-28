// デモの演出：新しいメモを書く → タグを付ける → 一覧から過去のメモを開く → カレンダーを見る。
// 画面外ではページのタイマーが間引かれるため、撮影側が1コマ（0.1秒）ごとに window.__demoStep(コマ番号) を呼んで進める。
(() => {
  const key = (target, key, meta = false) => target.dispatchEvent(new KeyboardEvent("keydown", { key, metaKey: meta, bubbles: true, cancelable: true }));
  const $ = (selector) => document.querySelector(selector);
  const timeline = [];
  let at = 8;
  const pause = (frames) => { at += frames; };
  const act = (action) => { timeline.push([at, action]); };
  const typeBody = (text, speed = 1) => { for (const character of text) { act(() => { $("#memoBody").focus(); document.execCommand(character === "\n" ? "insertParagraph" : "insertText", false, character === "\n" ? null : character); }); pause(character === "\n" ? 3 : speed); } };
  const typeInput = (selector, text) => { for (const character of text) { act(() => { const input = $(selector); input.value += character; input.dispatchEvent(new Event("input", { bubbles: true })); }); pause(2); } };

  act(() => { const range = document.createRange(); range.selectNodeContents($("#memoBody")); range.collapse(false); getSelection().removeAllRanges(); getSelection().addRange(range); $("#memoBody").focus(); });
  pause(2);
  typeBody("リリース前の確認\n・README にデモを入れる\n・アイコンを差し替える");
  pause(8);
  act(() => key(document, "t", true)); pause(7);
  typeInput("#tagInput", "会議"); pause(6);
  act(() => key($("#tagInput"), "Enter")); pause(8);
  act(() => key(document, "Escape")); pause(10);
  act(() => key(document, "o", true)); pause(14);
  for (let i = 0; i < 2; i += 1) { act(() => key($("#listInput"), "ArrowDown")); pause(6); }
  pause(4);
  act(() => key($("#listInput"), "Enter")); pause(16);
  act(() => $(".memo-calendar-button").click()); pause(26);
  act(() => key(document, "Escape")); pause(6);
  window.__demoFrames = at;
  window.__demoStep = (frame) => { for (const [when, action] of timeline) if (when === frame) action(); };
})();
