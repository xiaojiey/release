#!/bin/bash
# prerequest: Build check-payload
#git clone https://gitlab.cee.redhat.com/rphillip/check-payload.git
#cd check-payload
#make

start_time=`date +"%Y-%m-%d %H:%M:%S"`
data_dir=`pwd`
catalog_image=$1
operator_packages=$2
#catalog_image="brew.registry.redhat.io/rh-osbs/iib-pub-pending:v4.10"
#catalog_image="registry.redhat.io/redhat/redhat-operator-index:v4.10"
catalog_type="internal"  #when catalog_type=internal, the registry.redhat.io will be replaced to brew.registry.redhat.io
operator_catalog_file="${data_dir}/catalog.json"
operator_select_file="${data_dir}/selected_operators"

if [[ $catalog_image == "" ]]; then
	echo "Please input the index image. For example, quay.io/openshift-qe-optional-operators/aosqe-index:v4.11"
	exit 1
fi

if [[ $operator_packages != "" ]]; then
	rm -f ${operator_select_file}
	for i in ${@: 2:$#}; do
		echo $i >> ${operator_select_file}
	done
else
	echo "Warning! No operator package specific, scanning all operators in the ${catalog_image}"
	opm alpha list packages ${catalog_image} | awk 'NR>=2 {print $1}' >${operator_select_file}
fi

echo "The following operator will be scaned in ${catalog_image}"
cat ${data_dir}/selected_operators

opm render ${catalog_image} -o json >${operator_catalog_file}

#Scan image per operator(package), the latest csv in each channel will be scaned
for package in $(cat ${operator_select_file}); do
    mkdir $data_dir/${package} || true
    rm -rf $data_dir/${package}/*
    image_list="$data_dir/${package}/image_list.txt"
    #loop each channel
    for channel in $(jq -r 'select(.schema=="olm.channel" and .package=="'$package'")|.name' $operator_catalog_file|sort -V|uniq); do
	# get the latest bundle name of channel
	bundle_name=$(jq -r 'select(.schema=="olm.channel" and .package=="'$package'" and .name=="'$channel'")|.entries[].name' $operator_catalog_file|sort -rV|awk 'NR==1')
        scan_result_bundle_file="$data_dir/${package}/${bundle_name}.result"
        for image_name in $(jq -r 'select(.schema=="olm.bundle" and .name=="'$bundle_name'")|.relatedImages[].name' $operator_catalog_file); do
            image_url=$(jq -r 'select(.schema=="olm.bundle" and .name=="'$bundle_name'")|.relatedImages[]|select(.name=="'$image_name'")|.image' $operator_catalog_file)
            if [ $catalog_type == "internal" ]; then
               image_url=${image_url//registry.redhat.io/brew.registry.redhat.io}
	       image_url=${image_url//registry.stage.redhat.io/brew.registry.redhat.io}
            fi
            echo "## scan $image_name ->  $image_url" |tee -a $scan_result_bundle_file
            echo "$image_url">>$image_list
            nohup sudo ./check-payload scan operator --spec $image_url |& tee -a $scan_result_bundle_file
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
    cat >"${ARTIFACT_DIR}/junit/fips-check-node-scan.xml" <<EOF
    <testsuite name="fips scan" tests="1" failures="0">
        <testcase name="fips-check-node-scan"/>
        <succeed message="">Test pass, check the details from below</succeed>
        <system-out>
          $out
        </system-out>
    </testsuite>
EOF
else
    echo "Test fail, please check log."
    cat >"${ARTIFACT_DIR}/junit/fips-check-node-scan.xml" <<EOF
    <testsuite name="fips scan" tests="1" failures="1">
      <testcase name="fips-check-node-scan">
        <failure message="">Test fail, check the details from below</failure>
        <system-out>
          $out
        </system-out>
      </testcase>
    </testsuite>
EOF
fi
