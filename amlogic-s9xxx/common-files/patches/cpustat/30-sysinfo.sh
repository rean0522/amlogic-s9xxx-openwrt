#!/bin/bash
#
# DO NOT EDIT THIS FILE but add config options to /etc/default/motd
# any changes will be lost on board support package update
#
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

THIS_SCRIPT="sysinfo"
MOTD_DISABLE=""

SHOW_IP_PATTERN="^[ewr].*|^br.*|^lt.*|^umts.*"

# Find the partition where root is located
ROOT_PTNAME=$(df / | tail -n1 | awk '{print $1}' | awk -F '/' '{print $3}')
if [ "${ROOT_PTNAME}" == "" ]; then
	echo "Cannot find the partition corresponding to the root file system!"
	exit 1
fi

# Find the disk where the partition is located, only supports mmcblk?p? sd?? hd?? vd?? and other formats
case ${ROOT_PTNAME} in
mmcblk?p[1-4])
	EMMC_NAME=$(echo ${ROOT_PTNAME} | awk '{print substr($1, 1, length($1)-2)}')
	PARTITION_NAME="p"
	LB_PRE="EMMC_"
	;;
[hsv]d[a-z][1-4])
	EMMC_NAME=$(echo ${ROOT_PTNAME} | awk '{print substr($1, 1, length($1)-1)}')
	PARTITION_NAME=""
	LB_PRE=""
	;;
*)
	echo "Unable to recognize the disk type of ${ROOT_PTNAME}!"
	exit 1
	;;
esac
PARTITION_PATH="/mnt/${EMMC_NAME}${PARTITION_NAME}4"

[[ -f /etc/default/motd ]] && . /etc/default/motd
for f in $MOTD_DISABLE; do
	[[ $f == $THIS_SCRIPT ]] && exit 0
done

# don't edit below here
function display() {
	# $1=name $2=value $3=red_limit $4=minimal_show_limit $5=unit $6=after $7=acs/desc{
	# battery red color is opposite, lower number
	if [[ "$1" == "Battery" ]]; then
		local great="<"
	else
		local great=">"
	fi
	if [[ -n "$2" && "$2" > "0" && (("${2%.*}" -ge "$4")) ]]; then
		printf "%-5s%s" "$1:"
		if awk "BEGIN{exit ! ($2 $great $3)}"; then
			echo -ne "\e[0;91m $2"
		else
			echo -ne "\e[0;92m $2"
		fi
		printf "%-1s%s\x1B[0m" "$5"
		printf "%-9s%s\t" "$6"
		return 1
	else
		printf "%-5s%s" "$1:"
		echo -ne "\e[0;92m $2"
		printf "%-1s%s\x1B[0m" "$5"
		printf "%-9s%s\t" "$6"
		return 1
	fi
} # display

function get_ip_addresses() {
	local ips=()
	for f in /sys/class/net/*; do
		local intf=$(basename $f)
		# match only interface names starting with e (Ethernet), br (bridge), w (wireless), r (some Ralink drivers use ra<number> format)
		if [[ $intf =~ $SHOW_IP_PATTERN ]]; then
			local tmp=$(ip -4 addr show dev $intf | awk '/inet/ {print $2}' | cut -d'/' -f1)
			# add both name and IP - can be informative but becomes ugly with long persistent/predictable device names
			#[[ -n $tmp ]] && ips+=("$intf: $tmp")
			# add IP only
			[[ -n $tmp ]] && ips+=("$tmp")
		fi
	done
	echo "${ips[@]}"
} # get_ip_addresses

function storage_info() {
	# storage info
	RootInfo=$(df -h /)
	root_usage=$(awk '/\// {print $(NF-1)}' <<<${RootInfo} | sed 's/%//g')
	root_total=$(awk '/\// {print $(NF-4)}' <<<${RootInfo})

	# storage info
	BootInfo=$(df -h /boot)
	boot_usage=$(awk '/\// {print $(NF-1)}' <<<${BootInfo} | sed 's/%//g')
	boot_total=$(awk '/\// {print $(NF-4)}' <<<${BootInfo})

	# Get the size of the extended partition
	if [ -d "${PARTITION_PATH}" ]; then
		PartInfo=$(df -h ${PARTITION_PATH})
		data_usage=$(awk '/\// {print $(NF-1)}' <<<${PartInfo} | sed 's/%//g')
		data_total=$(awk '/\// {print $(NF-4)}' <<<${PartInfo})
	fi
}

function get_data_storage() {
	if which lsblk >/dev/null; then
		root_name=$(lsblk -l -o NAME,MOUNTPOINT | awk '$2~/^\/$/ {print $1}')
		mmc_name=$(echo $root_name | awk '{print substr($1,1,length($1)-2);}')
		if echo $mmc_name | grep mmcblk >/dev/null; then
			DATA_STORAGE="/mnt/${mmc_name}p4"
		fi
	fi
}

# query various systems and send some stuff to the background for overall faster execution.
# Works only with ambienttemp and batteryinfo since A20 is slow enough :)
ip_address=$(get_ip_addresses &)
get_data_storage
storage_info
critical_load=$((1 + $(grep -c processor /proc/cpuinfo) / 2))

# get uptime, logged in users and load in one take
if [ -x /usr/bin/cpustat ]; then
	time=$(/usr/bin/cpustat -u)
	load=$(/usr/bin/cpustat -l)
else
	UptimeString=$(uptime | tr -d ',')
	time=$(awk -F" " '{print $3" "$4}' <<<"${UptimeString}")
	load="$(awk -F"average: " '{print $2}' <<<"${UptimeString}")"
	case ${time} in
	1:*) # 1-2 hours
		time=$(awk -F" " '{print $3" h"}' <<<"${UptimeString}")
		;;
	*:*) # 2-24 hours
		time=$(awk -F" " '{print $3" h"}' <<<"${UptimeString}")
		;;
	*day) # days
		days=$(awk -F" " '{print $3"d"}' <<<"${UptimeString}")
		time=$(awk -F" " '{print $5}' <<<"${UptimeString}")
		time="$days "$(awk -F":" '{print $1"h "$2"m"}' <<<"${time}")
		;;
	esac
fi

# memory
mem_info=$(LC_ALL=C free -w 2>/dev/null | grep "^Mem" || LC_ALL=C free | grep "^Mem")
memory_usage=$(awk '{printf("%.0f",(($2-($4+$6))/$2) * 100)}' <<<${mem_info})
memory_total=$(awk '{printf("%d",$2/1024)}' <<<${mem_info})

# swap
swap_info="$(free -m | sed -n '$p' | echo $(xargs))"
swap_usage=$(awk '{printf("%d", $3/$2*100)}' <<<${swap_info} 2>/dev/null || echo 0)
swap_total=$(awk '{printf("%d", $2/1024)}' <<<${swap_info} 2>/dev/null || echo 0)

# cpu temp
if grep -q "ipq40xx" "/etc/openwrt_release"; then
	cpu_temp="$(sensors | grep -Eo '\+[0-9]+.+C' | sed ':a;N;$!ba;s/\n/ /g;s/+//g')"
elif [ -f "/sys/class/hwmon/hwmon0/temp1_input" ]; then
	cpu_temp="$(awk '{ printf("%.1f °C", $0 / 1000) }' /sys/class/hwmon/hwmon0/temp1_input)"
elif [ -f "/sys/class/thermal/thermal_zone0/temp" ]; then
	cpu_temp="$(awk '{ printf("%.1f °C", $0 / 1000) }' /sys/class/thermal/thermal_zone0/temp)"
else
	cpu_temp="50.0 °C"
fi
cpu_tempx=$(echo $cpu_temp | sed 's/°C//g')

# Architecture
if [ -x /usr/bin/cpustat ]; then
	sys_temp=$(/usr/bin/cpustat -A)
else
	sys_temp=$(cat /proc/cpuinfo | grep name | cut -f2 -d: | uniq )
fi
sys_tempx=$(echo $sys_temp | sed 's/ / /g')

# display info
machine_model=$(cat /proc/device-tree/model | tr -d "\000")
printf " Device Model: \x1B[93m%s\x1B[0m" "${machine_model}"
echo ""
printf " Architecture: \x1B[93m%s\x1B[0m" "$sys_tempx"
echo ""
display " Load Average" "${load%% *}" "${critical_load}" "0" "" "${load#* }"
printf "Uptime: \x1B[92m%s\x1B[0m" "$time"
echo ""

display " Ambient Temp" "$cpu_tempx" "80" "0" "" "°C"
if [ -x /usr/bin/cpustat ]; then
	cpu_freq=$(/usr/bin/cpustat -F1500)
	echo -n "CPU Freq: $cpu_freq"
else
	display "CPU Freq" "$cpu_freq" "1500" "0" " Mhz" ""
fi
echo ""

display " Memory Usage" "$memory_usage" "70" "0" "%" " of ${memory_total}M"
display "Swap Usage" "$swap_usage" "80" "0" "%" " of ${swap_total}M"
echo ""

display " Boot Storage" "$boot_usage" "90" "1" "%" " of $boot_total"
display "ROOTFS" "$root_usage" "90" "1" "%" " of $root_total"
echo ""

if [ -d "${PARTITION_PATH}" ]; then
	display " Data Storage" "$data_usage" "90" "0" "%" " of ${data_total}"
	printf "IP Addr: \x1B[92m%s\x1B[0m" "$ip_address"
	echo ""
fi
echo " -------------------------------------------------------"
