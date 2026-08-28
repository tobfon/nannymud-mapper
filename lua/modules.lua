-- Ordered module list for the mapper client. Read by the XML bootstrap's elro.load_modules on
-- every load/mapreload, and by the offline harnesses. Order matters: geom and keys are preludes
-- others bind into locals; core owns elro.exits/elro.clk; tune owns elro.TUNE; canvas owns
-- elro.area_adjacency.
return {
  "geom.lua", "keys.lua", "core.lua", "tune.lua", "canvas.lua", "audit.lua", "topo.lua",
  "levers.lua", "eqw.lua", "eqlevers.lua", "place.lua", "walk.lua", "render.lua", "vert.lua",
}
