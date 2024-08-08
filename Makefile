# Toplevel Makefile for Magero project.
#
# For debug builds:
#
#   make
#
# For release builds:
#
#   make release
#
# Only `pdc` from Playdate SDK is needed for these, plus a few standard
# command line tools.
#
# To refresh game data and build, do one of the following:
#
#   make -j refresh_data && make
#   make -j refresh_data && make release
#
# Refreshing game data requires a few more tools and libraries, see
# data/Makefile for more information.  At a minimum, you will likely need
# to edit data/svg_to_png.sh to set the correct path to Inkscape.

package_name=magero
data_dir=data
source_dir=source
release_source_dir=release_source

# Debug build.
$(package_name).pdx/pdxinfo: \
	$(source_dir)/main.lua \
	$(source_dir)/arm.lua \
	$(source_dir)/util.lua \
	$(source_dir)/world.lua \
	$(source_dir)/data.lua \
	$(source_dir)/pdxinfo
	pdc $(source_dir) $(package_name).pdx

# Release build.
release: $(package_name).zip

$(package_name).zip:
	-rm -rf $(package_name).pdx $(release_source_dir) $@
	cp -R $(source_dir) $(release_source_dir)
	for i in $(source_dir)/*.lua; do perl $(data_dir)/strip_lua.pl $$i > $(release_source_dir)/`basename $$i`; done
	pdc -s $(release_source_dir) $(package_name).pdx
	zip -9 -r $@ $(package_name).pdx

# Refresh data files in source directory.
refresh_data:
	$(MAKE) -C $(data_dir)
	cp -f $(data_dir)/arm-table-138-138.png $(source_dir)/images/
	cp -f $(data_dir)/finger-table-70-70.png $(source_dir)/images/
	cp -f $(data_dir)/cursor*.png $(source_dir)/images/
	cp -f $(data_dir)/help*.png $(source_dir)/images/
	cp -f $(data_dir)/debris-table-62-55.png $(source_dir)/images/
	cp -f $(data_dir)/world-table-32-32.png $(source_dir)/images/
	cp -f $(data_dir)/ufo-table-121-37.png $(source_dir)/images/
	cp -f $(data_dir)/wrist.png $(source_dir)/images/
	cp -f $(data_dir)/card0.png $(source_dir)/launcher/card.png
	cp -f $(data_dir)/card0.png $(source_dir)/launcher/card-highlighted/1.png
	cp -f $(data_dir)/card1.png $(source_dir)/launcher/card-highlighted/2.png
	cp -f $(data_dir)/card2.png $(source_dir)/launcher/card-highlighted/3.png
	cp -f $(data_dir)/card3.png $(source_dir)/launcher/card-highlighted/4.png
	cp -f $(data_dir)/icon0.png $(source_dir)/launcher/icon.png
	cp -f $(data_dir)/icon0.png $(source_dir)/launcher/icon-highlighted/1.png
	cp -f $(data_dir)/icon1.png $(source_dir)/launcher/icon-highlighted/2.png
	cp -f $(data_dir)/icon2.png $(source_dir)/launcher/icon-highlighted/3.png
	cp -f $(data_dir)/icon3.png $(source_dir)/launcher/icon-highlighted/4.png
	cp -f $(data_dir)/launch_image.png $(source_dir)/launcher/launchImage.png
	cp -f $(data_dir)/loading*.png $(source_dir)/images/
	cp -f $(data_dir)/data.lua $(source_dir)/

clean:
	$(MAKE) -C $(data_dir) clean
	-rm -rf $(package_name).pdx $(package_name).zip $(release_source_dir)
