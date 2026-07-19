#!/bin/bash

echo "🎮 Zotac Zone 터치패드 비활성화 스크립트를 시작합니다..."

# 1. SteamOS Read-only 모드 해제
echo "[1/4] 파일 시스템 쓰기 권한을 활성화합니다 (steamos-readonly disable)..."
sudo steamos-readonly disable

# 2. udev 규칙 파일 생성 및 내용 쓰기
echo "[2/4] 터치패드 무력화 udev 규칙을 심는 중입니다..."
RULE_FILE="/etc/udev/rules.d/99-disable-zone-trackpad.rules"
# 작동이 확인된 오리지널 규칙 내용으로 변경
RULE_CONTENT='ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="ZOTAC Gaming Zone Mouse", MODE="0000", ENV{ID_INPUT}="", ENV{LIBINPUT_IGNORE_DEVICE}="1"'

# sudo 권한으로 파일에 내용 기록
echo "$RULE_CONTENT" | sudo tee "$RULE_FILE" > /dev/null

# 3. udev 갱신 및 트리거
echo "[3/4] 변경된 udev 규칙을 시스템에 적용합니다..."
sudo udevadm control --reload-rules
sudo udevadm trigger

# 4. SteamOS Read-only 모드 복구
echo "[4/4] 파일 시스템을 다시 읽기 전용(Read-only)으로 잠급니다..."
sudo steamos-readonly enable

echo "✅ 모든 작업이 완료되었습니다! 완벽한 적용을 위해 기기를 재부팅해 주세요."
