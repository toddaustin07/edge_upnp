--[[
  
  DESCRIPTION
  
  This is sample template for creating SmartThings Edge device drivers using the UPnP library

  ** This code borrows liberally from Samsung SmartThings sample LAN drivers; credit to Patrick Barrett **

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"                   -- cosock used only for sleep timers in this module
local socket = require "cosock.socket"
local log = require "log"

-- UPnP library
local upnp = require "UPnP"        

-- Search target for multicast discovery messages; can be: 'upnp:rootdevice' OR 'ssdp:all' OR 'uuid:xxxxxx...' OR 'urn:xxxxxx...'
local TARGETDEVICESEARCH = "ssdp:all"

-- Recognized device model names and their associated Edge capability profile
-------------------------------------------------------------------------------------
-- EDIT THIS TABLE TO INCLUDE DEVICES YOU WANT THIS DRIVER TO RECOGNIZE AND CREATE --
-------------------------------------------------------------------------------------
local profiles = {
  ["Announcer"] = "myprofiles.deviceprofile.v1", 
}

-- Duration (in seconds) to stay subscribed to device events (e.g. 24 hour duration = 86400)
local SUBSCRIBETIME = 300           

-- Temp UPnP metadata storage for newly created devices
local newly_added = {}


-- Callback for whenever a UPnP device sends an event for a subscribed service
local function event_callback(device, sid, sequence, propertylist)

  upnpdev = device:get_field("upnpdevice")

  -- 1. check to make sure this is an sid we recognize
 
  -- 2. Update SmartThings device states
  
  device:emit_event(...)
  
end


-- Subscribe to the desired UPnP device service
local function subscribe_device (device, serviceID, duration)

  local upnpdev = device:get_field('upnpdevice')
  
	local response = upnpdev:subscribe(serviceID, event_callback, duration, nil)

	if response ~= nil then

		-- 1. Examine timeout key value in response table to confirm expectation
		
		-- 2. Retrieve statevars array in response table for initial values

		-- 3. It is driver responsibility to save/manage subscription ids (sid)
		device:set_field("upnp_sid", response.sid)
		
		return response
		
	end
end

  
-- Periodic subscription renewal routine
local function resubscribe_all(driver)
  
  local device_list = driver:get_devices()

  for _, device in ipairs(device_list) do
    
    -- Determine if there is a subscription for this device
    local sid = device:get_field("upnp_sid")
    if sid then
      
      local upnpdev = device:get_field("upnpdevice")
      local name = upnpdev:devinfo().friendlyName
      
      -- Resubscribe only if the device is online
      if upnpdev.online then
        upnpdev:unsubscribe(sid)
        device:set_field("upnp_sid", nil)
        local serviceID = device:get_field("upnp_serviceID")
        log.info(string.format("Re-subscribing to %s", name))
        subscribe_device(device, serviceID, SUBSCRIBETIME)
      else
        log.warn(string.format("%s is offline, can't re-subscribe now", name))
      end
    end
  end
  
end


-- Callback to handle UPnP device status & config changes; invoked by the UPnP library device monitor 
local function status_changed_callback(device)
  
  -- 1.Examine upnp device metadata for important changes (online/offline status, bootid, configid, etc)
  
  local upnpdev = device:get_field("upnpdevice")
  local sid = device:get_field("upnp_sid")
  
  if upnpdev.online then
  
    log.info ("Device is back online")
    device:online()
    
    -- 2.Refresh SmartThings capability attributes

    -- 3.Refresh any important values from device and service descriptions
    
    -- 4.Send any necessary commands to device
    
    -- 5.Restart subscription for the device
    
    if sid then
      local serviceID = device:get_field("upnp_serviceID")
      subscribe_device (device, serviceID, SUBSCRIBETIME)
    end  
    
  else
    log.info ("Device has gone offline")
    device:offline()
    if sid then
      upnpdev:cancel_resubscribe(sid)
    end
  end
end


-- Example routine to send a command to the UPnP device
local function send_commandx(upnpdev, serviceID)
  
  local cmd
  local name = upnpdev:devinfo().friendlyName
  
    -- Set up the service action name and arguments table  
    cmd = { action = 'PlayMessage',
            arguments = {
              ['MessageText'] = 'U-P-N-P device has started',
              ['SpeakingVoice'] = 'en-US_MichaelV3Voice',
              ['AudioOutput'] = 'local',
              ['Volume'] = 80,
            }
          }
                
  end
  
  status, response = upnpdev:command(serviceID, cmd)
    
  if status == 'OK' then
    -- response table contains returned state values from UPnP device

  elseif status == 'Error' then
    -- response table contains returned error information from UPnP device

  end

end
  
  
-- Here is where we perform all our device startup tasks
local function startup_device(driver, device, upnpdev)

  -- MANDATORY: links UPnP device metadata to SmartThings device object, and ST driver & device info to UPnP device metadata
  upnpdev:init(driver, device)                 -- creates 'upnpdevice' field in device object (among other things) 

  -- INITIALIZE UPNP DEVICE ONLINE/OFFLINE MONITORING
  upnpdev:monitor(status_changed_callback)     -- invoke given callback whenever UPnP device online status changes
  
  -- SET INITIAL SMARTTHINGS DEVICE STATE & ATTRIBUTES (before subscribing or issuing device commands, which will update it)
  device:online()
  device:emit_event(capabilities.switch.switch('off'))
  
  -- Do other device startup stuff here
  -- . . .
  
  -- GET THE DEVICE SERVICE ID THAT WE'LL USE FOR SUBSCRIPTIONS AND COMMANDS
  local serviceID
  
  if upnpdev.description.device.services then														-- make sure there IS a services section in device description
  
    if upnpdev.description.device.services[1] then											-- make sure there is at least one service available
  
      serviceID = upnpdev.description.device.services[1].serviceId      -- get the serviceId
      device:set_field('upnp_serviceID', serviceID)                     --   > we'll want to refer to this elsewhere, so store it
  
      -- RETRIEVE AND INSPECT THE SERVICE DESCRIPTION INFO (optional)
      local service_description = upnpdev:getservicedescription(serviceID)
      -- >> here is where you could parse service_description for available commands and state variables

      -- SUBSCRIBE TO THE DESIRED SERVICE
      --   (subscription renewals will be initiated by periodic timer that we set up during driver initialization)
      subscribe_device(device, serviceID, SUBSCRIBETIME) 
    
    else
      log.warn ('Chosen service not available for device')
    end
    
  else
    log.warn ('No Services available for device')
  end
  
  
  -- SEND DEVICE INITIALIZING COMMANDS IF NEEDED
  
  send_commandx(upnpdev, serviceID)
  
end


------------------------------------------------------------------------
--	      SMARTTHINGS DEVICE CAPABILITY COMMAND HANDLERS
------------------------------------------------------------------------

local function handle_switch_on(_, device)

	local upnpdev = device:get_field('upnpdevice')
	local serviceID = device:get_field('upnp_serviceID')

	-- Update the capability
	device:emit_event(...)
	
	-- Send an appropriate command to the UPnP device
	send_command1(upnpdev, serviceID)
    
end

local function handle_switch_off(_, device)
  
  local upnpdev = device:get_field('upnpdevice')
	local serviceID = device:get_field('upnp_serviceID')

	-- Update the capability
	device:emit_event(...)
	
	-- Send an appropriate command to the UPnP device
	send_command2(upnpdev, serviceID) 
    
end

function handle_refresh(_, device)
  
  local upnpdev = device:get_field('upnpdevice')
	local serviceID = device:get_field('upnp_serviceID')

	-- Update the capability
	device:emit_event(...)
	
	-- Send an appropriate command to the UPnP device
	send_command3(upnpdev, serviceID)  
    
end

  
------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
  -- retrieve UPnP device metadata if it exists
  local upnpdev = device:get_field("upnpdevice")
  
  if upnpdev == nil then                    -- if nil, then this handler was called to initialize an existing device (eg driver reinstall)
  
    local waittime = 1                      -- initially try for a quick response since it's a known device
     
    -- NOTE: a specific search target must include prefix (eg 'uuid:') for SSDP searches                                        
    local searchtarget = 'uuid:' .. device.device_network_id            
    
    while waittime <= 3 do
      upnp.discover(searchtarget, waittime, function(devobj) upnpdev = devobj end)
      if upnpdev then 
        if device.device_network_id == upnpdev.uuid then
          break
        end
      end
      upnpdev = nil
      waittime = waittime + 1   
      if waittime <= 3 then
        socket.sleep(2)
      end
    end
  
    if not upnpdev then
      log.warn("<" .. device.id .. "> not found on network")
      return
      
    else
    
			-- Perform startup tasks for the device
      startup_device(driver, device, upnpdev)
      
    end
    
  else
    -- nothing else needs to be done if device metadata already available (already handled in device_added)
  end
end


-- Called when device is initially discovered and created in SmartThings
local function device_added (driver, device)

  local id = device.device_network_id

  -- get UPnP metadata that was squirreled away when device was created
  upnpdev = newly_added[id]
  
  startup_device(driver, device, upnpdev)
    
  newly_added[id] = nil     -- we're done with it
  
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

	-- determined by developer

end


-- Called when device was deleted
local function device_removed(_, device)
  
  log.info("<" .. device.id .. "> removed")
  
  local upnpdev = device:get_field("upnpdevice")
  
  -- Clean up any outstanding event subscriptions
  
	local sid = device:get_field("upnp_sid")
	if sid ~= nil then
		upnpdev:unsubscribe(sid)
		upnpdev:cancel_resubscribe(sid)
		device:set_field("upnp_sid", nil)
	end  
	
	-- stop monitoring & allow for later re-discovery 
	upnpdev:forget()                                                    
    
end


-- Take any needed action when device information has changed
local function handler_infochanged(driver, device, event, args)

  -- determined by developer
  
end


-- If the hub's IP address changes, this handler is called
local function lan_info_changed_handler(driver, hub_ipv4)

  if driver.listen_ip == nil or hub_ipv4 ~= driver.listen_ip then
  
		-- reset device monitoring and subscription event server
    upnp.reset(driver)
    -- renew all subscriptions
    resubscribe_all(driver)
  end
end


-- Perform SSDP discovery to find target device(s) on the LAN
local function discovery_handler(driver, _, should_continue)
  
  local known_devices = {}
  local found_devices = {}

  local device_list = driver:get_devices()
  for _, device in ipairs(device_list) do
    local id = device.device_network_id
    known_devices[id] = true
  end

  local repeat_count = 3
  local searchtarget = TARGETDEVICESEARCH
  local waittime = 3                          -- allow LAN devices 3 seconds to respond to discovery requests

  -- We'll limit our discovery to repeat_count to minimize unnecessary LAN traffic

  while should_continue and (repeat_count > 0) do
    log.debug("Making discovery request #" .. ((repeat_count*-1)+4) .. '; for target: ' .. searchtarget)
    
    --****************************************************************************
    upnp.discover(searchtarget, waittime,    
                  function (upnpdev)
    
                    local id = upnpdev.uuid
                    local ip = upnpdev.ip
                    local modelname
                    local name

                    if not known_devices[id] and not found_devices[id] then
                      found_devices[id] = true

                      modelname = upnpdev:devinfo().modelName
                      name = upnpdev:devinfo().friendlyName
                        
                      local devprofile = profiles[modelname]

                      -- Here is where we examine the UPnP device metadata to see if it is a device we are looking for;
                      -- This can be based on model, but also a device or service type (urn), uuid, or combo of both(usn);
                      -- For our purposes here, we'll accept any model names that are contained in our profiles table

                      if devprofile then                

                        local create_device_msg = {
                          type = "LAN",
                          device_network_id = id,
                          label = name,
                          profile = devprofile,
                          manufacturer = upnpdev:devinfo().manufacturer,
                          model = modelname,
                          vendor_provided_label = name,
                        }
                        
                        log.info(string.format("Creating discovered device: %s / %s at %s", name, modelname, ip))
                        log.info("\tupnp uuid  = device_network_id = ", id)

												-- squirrel away UPnP device metadata for device_added handler
												--   > because there's currently no way to attach it to the new device here :-(
                        newly_added[id] = upnpdev
                        
                        -- create the device
                        assert (driver:try_create_device(create_device_msg), "failed to create device record")

                      else
                        log.warn(string.format("Discovered device not recognized (name: %s / model: %s)", name, modelname))
                      end
                    else
                      --log.debug("Discovered device was already known")
                    end
                  end
    )
    --***************************************************************************
    
    repeat_count = repeat_count - 1
    if repeat_count > 0 then
      socket.sleep(2)                          -- avoid creating network storms
    end
  end
  log.info("Driver is exiting discovery")
end

-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
local upnpDriver = Driver("upnpDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    deleted = device_removed,
    removed = device_removed,
  },
  lan_info_changed_handler = lan_info_changed_handler,
  capability_handlers = {
  
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off,
    },
   
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    }
   
  }
})

-- Initialize scheduler to periodically run subscription renewal routine
upnpDriver:call_on_schedule(SUBSCRIBETIME-5, resubscribe_all , "Re-subscribe timer")

upnpDriver:run()
