#!/bin/bash

apply_sed_to_matches() {
	local SEARCH_DIR=$1
	local FILE_NAME=$2
	local SED_EXPR=$3
	local MATCHES

	MATCHES=$(find "$SEARCH_DIR" -type f -name "$FILE_NAME" 2>/dev/null)
	if [ -n "$MATCHES" ]; then
		while IFS= read -r TARGET_FILE; do
			sed -i "$SED_EXPR" "$TARGET_FILE"
		done <<< "$MATCHES"
	fi
}

#移除luci-app-attendedsysupgrade
apply_sed_to_matches "./feeds/luci/collections/" "Makefile" "/attendedsysupgrade/d"

#修改默认主题
#sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#sed -i "s/luci-theme-.*$/luci-theme-bootstrap/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")

#修改immortalwrt.lan关联IP
apply_sed_to_matches "./feeds/luci/modules/luci-mod-system/" "flash.js" "s/192\\.168\\.[0-9]*\\.[0-9]*/$WRT_IP/g"
#添加编译日期标识
apply_sed_to_matches "./feeds/luci/modules/luci-mod-status/" "10_system.js" "s/(\\(luciversion || ''\\))/(\\1) + (' \\/ $WRT_MARK-$WRT_DATE')/g"

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	#sed -i "s/country='.*'/country='US'/g" $WIFI_UC
	#修改WIFI加密
	#sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

# =========================================================
# 智能系统调优：优化内存水位线 (min_free_kbytes)
# =========================================================

MIN_FREE_VAL=16384
CONF_FILE="./package/base-files/files/etc/sysctl.conf"

# 提取当前值（只匹配非注释、行首）
CURRENT_VAL=$(sed -n 's/^vm\.min_free_kbytes=\([0-9]\+\).*/\1/p' "$CONF_FILE")

if [ -z "$CURRENT_VAL" ]; then
    echo "" >> "$CONF_FILE"
    echo "vm.min_free_kbytes=$MIN_FREE_VAL" >> "$CONF_FILE"
    echo "Memory patch: value not found, added $MIN_FREE_VAL."
else
    if [ "$CURRENT_VAL" -lt "$MIN_FREE_VAL" ]; then
        sed -i "s/^vm\.min_free_kbytes=.*/vm.min_free_kbytes=$MIN_FREE_VAL/" "$CONF_FILE"
        echo "Memory patch: upgraded $CURRENT_VAL -> $MIN_FREE_VAL."
    else
        echo "Memory patch: current value ($CURRENT_VAL) is sufficient, skipped."
    fi
fi

# 修复雅典娜 AX6600 2.5G 网口 (QCA8081) LED 不亮问题
DTS_FILE=$(find ./target/linux/qualcommax/ -name "ipq6010-re-cs-02.dts" 2>/dev/null)
if [ -f "$DTS_FILE" ]; then
    echo "Found $DTS_FILE, patching QCA8081 LEDs..."
    python3 -c '
import sys
path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

target = "reset-gpios = <&tlmm 77 GPIO_ACTIVE_LOW>;"
led_patch = """reset-gpios = <&tlmm 77 GPIO_ACTIVE_LOW>;

\t\tleds {
\t\t\t#address-cells = <1>;
\t\t\t#size-cells = <0>;

\t\t\tled@0 {
\t\t\t\treg = <0>;
\t\t\t\tcolor = <LED_COLOR_ID_GREEN>;
\t\t\t\tfunction = LED_FUNCTION_WAN;
\t\t\t\tdefault-state = "keep";
\t\t\t};

\t\t\tled@1 {
\t\t\t\treg = <1>;
\t\t\t\tcolor = <LED_COLOR_ID_AMBER>;
\t\t\t\tfunction = LED_FUNCTION_WAN;
\t\t\t\tdefault-state = "keep";
\t\t\t};
\t\t};"""

if target in content and "leds {" not in content:
    content = content.replace(target, led_patch, 1)
    with open(path, "w") as f:
        f.write(content)
    print("QCA8081 LED patch applied successfully!")
' "$DTS_FILE"
fi

# 解锁马来西亚 (MY) 的无线发射功率限制至 30 dBm
REGDB_FILE=$(find ./package/firmware/wireless-regdb/ -name "db.txt" 2>/dev/null)
if [ -f "$REGDB_FILE" ]; then
    echo "Found $REGDB_FILE, unlocking MY regulatory power to 30 dBm..."
    python3 -c '
import sys, re
path = sys.argv[1]
with open(path, "r") as f:
    text = f.read()
# 找到 country MY: 段落，将其中的 (24)、(20)、(23) 全部替换为 (30)
def unlock_my(match):
    block = match.group(0)
    block = re.sub(r"\((20|23|24)\)", "(30)", block)
    return block
text = re.sub(r"country MY:.*?(?=country |\Z)", unlock_my, text, flags=re.DOTALL)
with open(path, "w") as f:
    f.write(text)
print("MY regulatory power successfully unlocked to 30 dBm!")
' "$REGDB_FILE"
fi
