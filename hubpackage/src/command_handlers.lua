
local capabilities = require "st.capabilities"
local log = require "log"

local command_handlers = {}


function command_handlers.handle_switch_on(_, device)
    log.info("switch changed to ON")
    device:emit_event(capabilities.switch.switch('on'))
    
end

function command_handlers.handle_switch_off(_, device)
    log.info("switch changed to OFF")
    device:emit_event(capabilities.switch.switch('off'))
end


function command_handlers.handle_refresh(_, device)
  log.info("refresh")
  device:emit_event(capabilities.switch.switch('off'))
    
end

return command_handlers
