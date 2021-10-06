#!/usr/bin/env bash

CONFIG=${CONFIG:-cluster_config.sh}
if [ -r "$CONFIG" ]; then
	# shellcheck disable=SC1090
	source "./${CONFIG}"
fi

for arg in "$@"; do
  shift
  case "$arg" in
    "--delete-everything-older-than-5-hours") set -- "$@" "-f" ;;
    *) set -- "$@" "$arg"
  esac
done

declare resultfile='/dev/null'
declare DELETE=0

# shellcheck disable=SC2220
while getopts :o:f opt; do
	case "$opt" in
		o) resultfile="$OPTARG" ;;
		f) DELETE=1 ;;
	esac
done

if [ $DELETE != 1 ]; then
	echo "Refusing to run unless passing the --delete-everything-older-than-5-hours option"
	exit 5
fi

cat > "$resultfile" <<< '{}'

report() {
	declare \
		result='' \
		resource_type="$*"

	while read -r resource_id; do
		result=$(jq ".\"$resource_type\" += [\"$resource_id\"]" "$resultfile")
		cat > "$resultfile" <<< "$result"
		echo "$resource_id"
	done
}

leftover_clusters=$(./list-clusters.sh -ls)

for cluster_id in $leftover_clusters; do
	time ./destroy_cluster.sh -i "$(echo "$cluster_id" | report cluster)"
done

# Try again, this time via openstack commands directly
for cluster_id in $leftover_clusters; do
	time ./destroy_cluster.sh --force -i "$(echo "$cluster_id" | report cluster)"
done

# Clean leftover containers
openstack container list -f value -c Name \
	| grep -vf <(./list-clusters.sh -a) \
	| report container \
	| xargs --verbose --no-run-if-empty openstack container delete -r

for resource in 'volume snapshot' 'volume' 'floating ip' 'security group' 'keypair' 'loadbalancer'; do
	case $resource in
		volume)
			for r in $(./stale.sh -q "$resource"); do
				status=$(openstack "${resource}" show -c status -f value "${r}")
				case "$status" in
					# For Cinder volumes, deletable states are documented here:
					# https://docs.openstack.org/api-ref/block-storage/v3/index.html?expanded=delete-a-volume-detail#delete-a-volume
					available|in-use|error|error_restoring|error_extending|error_managing)
						break
						;;
					*)
						echo "${resource} ${r} in wrong state: ${status}, will try to set it to 'error'"
						openstack "$resource" set --state error "$r" || >&2 echo "Failed to set ${resource} ${r} state to error, ${r} will probably fail to be removed..."
						;;
				esac
			done
			# shellcheck disable=SC2086
			./stale.sh -q $resource | report $resource | xargs --verbose --no-run-if-empty openstack $resource delete
			;;
		loadbalancer)
		  for r in $(./stale.sh -q "$resource"); do
			status=$(openstack "${resource}" show -c provisioning_status -f value "${r}")
			case "$status" in
				ERROR)
					# shellcheck disable=SC2086
					report $resource | xargs --verbose openstack $resource delete --cascade
					;;
				*)
					;;
			esac
			done
			;;
		*)
			# shellcheck disable=SC2086
			./stale.sh -q $resource | report $resource | xargs --verbose --no-run-if-empty openstack $resource delete
			;;
	esac
done
