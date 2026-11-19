IVERILOG ?= iverilog
VVP      ?= vvp
CC       ?= cc
YOSYS    ?= yosys

SRC  = rtl/tr_div.sv rtl/tinyraster.sv
BUILD = build

.PHONY: test random quads edge render synth pnr-ecp5 clean

test: random quads edge

$(BUILD)/raster: model/raster.c
	@mkdir -p $(BUILD)
	$(CC) -O2 -Wall -Wextra -o $@ $<

$(BUILD)/sim: $(SRC) tb/tb_tinyraster.sv
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -o $@ $^

# 4000 random triangles, including clipped, degenerate and extreme-coordinate ones
random: $(BUILD)/raster $(BUILD)/sim
	$(BUILD)/raster gen 4000 1 > $(BUILD)/random.txt
	$(VVP) $(BUILD)/sim +tris=$(BUILD)/random.txt +out=$(BUILD)/random.px | grep "^done"
	$(BUILD)/raster run < $(BUILD)/random.txt > $(BUILD)/random.exp
	cut -d' ' -f1,3- $(BUILD)/random.px | cmp - $(BUILD)/random.exp
	@echo "random: $$(wc -l < $(BUILD)/random.exp) pixels identical to the C model"

edge: $(BUILD)/raster $(BUILD)/sim
	$(VVP) $(BUILD)/sim +tris=scenes/edge_cases.txt +out=$(BUILD)/edge.px | grep "^done"
	$(BUILD)/raster run < scenes/edge_cases.txt > $(BUILD)/edge.exp
	cut -d' ' -f1,3- $(BUILD)/edge.px | cmp - $(BUILD)/edge.exp
	@echo "edge: $$(wc -l < $(BUILD)/edge.exp) pixels identical to the C model"

# parallelograms split along both diagonals must cover the same pixels, once
quads: $(BUILD)/raster $(BUILD)/sim
	$(BUILD)/raster quads 500 1 > $(BUILD)/quads.txt
	$(VVP) $(BUILD)/sim +tris=$(BUILD)/quads.txt +out=$(BUILD)/quads.px | grep "^done"
	$(BUILD)/raster tiles < $(BUILD)/quads.px

# 320x240 demo scene -> docs/images/demo.png
render: $(BUILD)/raster
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2012 -Wno-timescale -P tb_tinyraster.SW=320 -P tb_tinyraster.SH=240 -o $(BUILD)/sim_demo $(SRC) tb/tb_tinyraster.sv
	$(VVP) $(BUILD)/sim_demo +tris=scenes/demo.txt +out=$(BUILD)/demo.px | tail -2
	$(CC) -O2 -o $(BUILD)/mkpng tools/mkpng.c
	$(BUILD)/mkpng 320 240 < $(BUILD)/demo.px > docs/images/demo.png

synth:
	$(YOSYS) -q -p "read_verilog -sv $(SRC); synth_ice40 -top tinyraster; tee -o $(BUILD)/synth_ice40.txt stat"
	@grep -E "SB_LUT4|SB_DFF|SB_CARRY|SB_MAC16|Number of cells" $(BUILD)/synth_ice40.txt

# optional: needs nextpnr-ecp5, not part of CI
pnr-ecp5:
	$(YOSYS) -q -p "read_verilog -sv $(SRC); synth_ecp5 -top tinyraster -json $(BUILD)/ecp5.json; tee -o $(BUILD)/synth_ecp5.txt stat"
	nextpnr-ecp5 --25k --package CABGA381 --json $(BUILD)/ecp5.json --freq 25 -q --log $(BUILD)/pnr_ecp5.log || true
	@grep "Max frequency" $(BUILD)/pnr_ecp5.log | tail -1

clean:
	rm -rf $(BUILD)
