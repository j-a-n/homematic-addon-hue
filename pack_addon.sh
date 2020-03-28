#!/bin/sh -e

version=$(cat VERSION)
addon_file="$(pwd)/hm-hue.tar.gz"
tmp_dir=$(mktemp -d)

for f in VERSION update_script addon ccu1 ccu2 ccurm hue; do
	[ -e  $f ] && cp -a $f "${tmp_dir}/"
done
chmod 755 "${tmp_dir}/update_script"

find $tmp_dir -iname "#*" -delete
(cd ${tmp_dir}; tar --owner=root --group=root --exclude ".*~" -czvf "${addon_file}" .)
rm -rf "${tmp_dir}"

dch -v "${version}-1" -D stable -b -m "new release, see github for changelog"
dpkg-buildpackage || true
cp ../hue_${version}-1_amd64.deb hue_amd64.deb

