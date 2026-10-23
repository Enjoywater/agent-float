#!/bin/sh
# 회사·개인 정보가 저장소에 들어가지 않게 커밋 전에 검사한다.
# 검사할 단어 목록은 커밋되지 않는 .git/info 아래에 두어, 검사 도구가 그 정보를 저장소에 퍼뜨리지 않게 한다
set -eu

words=$(git rev-parse --git-path info/privacy-words)
if [ ! -s "$words" ]; then
	echo "privacy-check: 단어 목록($words)이 없습니다. 검사할 단어를 한 줄에 하나씩 적어 주세요" >&2
	exit 2
fi

found=0
report() {
	echo "$1" >&2
	found=1
}

names=$(git ls-files | grep -i -F -f "$words" || true)
[ -z "$names" ] || report "파일 이름: $names"

contents=$(git ls-files -z | xargs -0 grep -n -i -I -F -f "$words" -- 2>/dev/null || true)
[ -z "$contents" ] || report "$contents"

# 작업 트리에서 이미 지운 단어라도 스테이징된 내용에 남아 있으면 그대로 커밋된다
staged=$(git diff --cached -U0 | grep '^+' | grep -i -F -f "$words" || true)
[ -z "$staged" ] || report "스테이징된 변경: $staged"

if [ "$found" -ne 0 ]; then
	echo "privacy-check: 회사·개인 정보가 있습니다" >&2
	exit 1
fi
echo "privacy-check: 0건"
