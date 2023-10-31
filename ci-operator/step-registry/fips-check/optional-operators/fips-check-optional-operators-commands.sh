#!/bin/bash
set -e
set -u
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}
function set_docker_config () {
    if test -s "~/.docker/config.json" ; then
        echo "setting the proxy"
        cp ~/.docker/config.json ~/.docker/config.json.backup
        cp /tmp/.dockerconfigjson ~/.docker/config.json
    else
        if [ ! -d "~/.docker/" ]; then
            cp /tmp/.dockerconfigjson ~/.docker/config.json
            chmod 644 ~/.docker/config.json
        fi
    fi
}
function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

set_proxy
run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
if [[ $ret -eq 0 ]]; then
    auths=`cat /tmp/.dockerconfigjson`
    if [[ $auths =~ "5000" ]]; then
        echo "This is a disconnected env, skip it."
        exit 0
    fi
fi

start_time=`date +"%Y-%m-%d %H:%M:%S"`
data_dir=`/tmp/optional-operators/`
package_list="/$data_dir/optional-operators-package-list-$RANDOM"
operator_catalog_file="/$data_dir/opertional-operators-catalog-files"
payload_version=`oc get clusterversion version -o=jsonpath='{.status.history[?(@.state == "Completed")].version}'`
if [[ $payload_version == "" ]]; then
	  echo "failed to get payload version"
	  exit 1
fi
version=${payload_version:0:4}
catalog_image="quay.io/openshift-qe-optional-operators/aosqe-index:v"+$verion
mkdir $data_dir
set_docker_config
opm alpha list packages ${catalog_image} | awk 'NR>=2 {print $1}' >/${package_list}
echo "The following operator will be scaned in ${catalog_image}"
cat ${package_list}
opm render ${catalog_image} -o json >${operator_catalog_file}

#Scan image per operator(package), the latest csv in each channel will be scaned
for package in $(cat /tmp/${package_list}); do
    mkdir -p ${data_dir}/${package} || true
    rm -rf /${data_dir}/${package}/*
    image_list="$data_dir/${package}/image_list.txt"
    #loop each channel
    for channel in $(jq -r 'select(.schema=="olm.channel" and .package=="'$package'")|.name' $operator_catalog_file|sort -V|uniq); do
	# get the latest bundle name of channel
	  bundle_name=$(jq -r 'select(.schema=="olm.channel" and .package=="'$package'" and .name=="'$channel'")|.entries[].name' $operator_catalog_file|sort -rV|awk 'NR==1')
        scan_result_bundle_file="$data_dir/${package}/${bundle_name}.result"
        for image_name in $(jq -r 'select(.schema=="olm.bundle" and .name=="'$bundle_name'")|.relatedImages[].name' $operator_catalog_file); do
            image_url=$(jq -r 'select(.schema=="olm.bundle" and .name=="'$bundle_name'")|.relatedImages[]|select(.name=="'$image_name'")|.image' $operator_catalog_file)
            image_url=${image_url//registry.redhat.io/brew.registry.redhat.io}
	          image_url=${image_url//registry.stage.redhat.io/brew.registry.redhat.io}
            echo "## scan $image_name ->  $image_url" |tee -a $scan_result_bundle_file
            echo "$image_url">>$image_list
            ./check-payload scan operator --spec $image_url |& tee -a $scan_result_bundle_file
        done
     done
     #delete images to save disk space
     sudo podman rm $(sudo podman ps -q -a) || true
     for image_url in $(cat ${image_list}); do
         sudo podman rmi ${image_url}  || true
     done
done

end_time=`date +"%Y-%m-%d %H:%M:%S"`
start_timestamp=$(date -d "$start_time" +%s)
end_timestamp=$(date -d "$end_time" +%s)
time_diff=$((end_timestamp - start_timestamp))
hours=$((time_diff / 3600))
minutes=$((time_diff % 3600 / 60))
seconds=$((time_diff % 60))
echo "===========================cost $hours hours $minutes mins $seconds s==========================="


# generate report
mkdir -p "${ARTIFACT_DIR}/junit"
if $pass; then
    echo "All tests pass!"
    cat >"${ARTIFACT_DIR}/junit/fips-check-optional-operators.xml" <<EOF
    <testsuite name="fips scan" tests="1" failures="0">
        <testcase name="fips-check-optional-operators"/>
        <succeed message="">Test pass, check the details from below</succeed>
        <system-out>
          $out
        </system-out>
    </testsuite>
EOF
else
    echo "Test fail, please check log."
    cat >"${ARTIFACT_DIR}/junit/fips-check-optional-operators.xml" <<EOF
    <testsuite name="fips scan" tests="1" failures="1">
      <testcase name="fips-check-optional-operators">
        <failure message="">Test fail, check the details from below</failure>
        <system-out>
          $out
        </system-out>
      </testcase>
    </testsuite>
EOF
fi
