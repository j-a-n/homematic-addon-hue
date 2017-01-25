#!/bin/sh -e

version=$(cat VERSION)
addon_file="$(pwd)/hm-hue.tar.gz"
tmp_dir=$(mktemp -d)

for f in update_script addon ccu1 ccu2 ccurm rc.d; do
	[ -e  $f ] && cp -a $f "${tmp_dir}/"
done
chmod 755 "${tmp_dir}/update_script"

(cd ${tmp_dir}; tar --owner=root --group=root --exclude ".*~" -czvf "${addon_file}" .)
rm -rf "${tmp_dir}"
