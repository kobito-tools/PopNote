#!/bin/zsh
cd "${0:A:h}"
./build.sh
status=$?
if [[ $status -eq 0 ]]; then
  echo ""
  echo "PopNote!.appを作成しました。アプリケーションフォルダへ移動し、OpenSesame!などのランチャーへ登録できます。"
  echo "PopNote!を使う前に、Tick Tock Tomeをセットアップしておいてください。"
fi
echo ""
read "reply?Enterキーで閉じます..."
exit $status
