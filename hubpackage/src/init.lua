--[[
  Copyright 2021 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  This is an example SmartThings Edge Driver using the generalized UPnP device library.  It will 
  discover, subscribe to, send commands to, and monitor online/offline status of, UPnP devices found on the network

  ** This code borrows liberally from Samsung SmartThings sample LAN drivers; credit to Patrick Barrett **

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"                   -- cosock used only for sleep timer in this module
local socket = require "cosock.socket"
local log = require "log"

-- UPnP library!
local upnp = require "UPnP"        

-- Driver-specific libraries
local command_handlers = require "command_handlers"

-- Custom capabilities for displaying some UPnP attributes
local upnpcap_model = capabilities["partyvoice23922.upnpmodel"]
local upnpcap_uuid = capabilities["partyvoice23922.upnpuuid"]
local upnpcap_urn = capabilities["partyvoice23922.upnpurn"]
local upnpcap_expiration = capabilities["partyvoice23922.upnpexpiration"]
local upnpcap_seqnum= capabilities["partyvoice23922.upnpseqnum"]


-- Search target for multicast discovery messages; can be: 'upnp:rootdevice' OR 'ssdp:all' OR 'uuid:xxxxxx...' OR 'urn:xxxxxx...'
local TARGETDEVICESEARCH = "ssdp:all"

-- Recognized device model names and their associated Edge capability profile
-------------------------------------------------------------------------------------
-- EDIT THIS TABLE TO INCLUDE DEVICES YOU WANT THIS DRIVER TO RECOGNIZE AND CREATE --
-------------------------------------------------------------------------------------
local profiles = {
  ["Pi 3 Model B"] = "myprofiles.genericupnp.v1",                       -- Raspberry Pi custom
  ["UN48J6203"] = "myprofiles.genericupnp.v1",                          -- Samsung TV
  ["Linksys RE6500"] = "myprofiles.genericupnp.v1",                     -- Linksys Range Extender  
  ["WPS"] = "myprofiles.genericupnp.v1",                                -- Linksys Router
  ["Philips hue bridge 2015"] = "myprofiles.genericupnp.v1",            -- Philips Hue Hub
  ["Linksys Series Router E3200"] = "myprofiles.genericupnp.v1",        -- Linksys Router
  ["3600X"] = "myprofiles.genericupnp.v1",                              -- Roku Stick
  ["3800X"] = "myprofiles.genericupnp.v1",                              -- Roku Stick
  ["DCS-936L"] = "myprofiles.genericupnp.v1",                           -- DLink Camera
  ["Insight"] = "myprofiles.genericupnp.v1",                            -- Belkin Wemo
  ["Socket"] = "myprofiles.genericupnp.v1",                             -- Belkin Wemo
  ["Dimmer"] = "myprofiles.genericupnp.v1",                             -- Belkin Wemo
  ["Sensor"] = "myprofiles.genericupnp.v1",                             -- Belkin Wemo
  ["Lightswitch"] = "myprofiles.genericupnp.v1",                        -- Belkin Wemo
}

local SUBSCRIBETIME = 300           -- Duration (in seconds) to stay subscribed to device events (24 hour duration = 86400)
local TIMEOFFSET = 5 * 60 * 60 * -1 -- Used for expiration time display in ST app; 5 is for U.S. Central Time Zone (use 4 for US Eastern)

local upnpDriver = {}

local newly_added = {}
local unfoundlist = {}

local swstate = {}

-- Refresh mobile app device capability attributes
local function update_ST_capattrs(device, seqnum)
  
  local upnpdev = device:get_field("upnpdevice")
  
  device:emit_event(upnpcap_model.model(upnpdev:devinfo().modelName))
  device:emit_event(upnpcap_uuid.uuid(upnpdev.uuid))
  device:emit_event(upnpcap_urn.urn(upnpdev:devinfo().deviceType or ''))
  device:emit_event(upnpcap_expiration.expiration(os.date("%I:%M:%S",upnpdev.expiration+TIMEOFFSET)))
  
  if seqnum then
    device:emit_event(upnpcap_seqnum.seqNum(seqnum))
  end

end

-- Callback for whenever a UPnP device sends an event for a subscribed service
local function event_callback(device, sid, sequence, propertylist)

  log.info ('Event received from: ' .. device.label)
  
  log.info ('\tSubscription ID: ' .. sid)                               -- can add a check to make sure this is an sid we recognize
  log.info ('\tSequence Number: ' .. tostring(sequence))
  log.info ('\tProperties:')
  
  for key, value in pairs(propertylist) do
    log.info ('\t\t' .. key .. ': ' .. value)
  end
  
  -- Update SmartThings device states...
  
  -- For fun, we'll flip the switch on the device card
  
  if (swstate[sid] == 'off') or (swstate[sid] == nil) then
    device:emit_event(capabilities.switch.switch('on'))
    swstate[sid] = 'on'
  else
    device:emit_event(capabilities.switch.switch('off'))
    swstate[sid] = 'off'
  end
  
  -- Update SmartThings device capability attributes
  update_ST_capattrs(device, sequence)
  
end


-- Subscribe to the desired UPnP device service
local function subscribe_device (device, serviceID, duration)

  local upnpdev = device:get_field('upnpdevice')
  
  if serviceID then
    local response = upnpdev:subscribe(serviceID, event_callback, duration, nil)
                                                                        -- last parm is optional state variable list to subscribe to
    if response ~= nil then
      if response.sid then
        log.info (string.format("Subscribed to %s; returned SID = %s", serviceID, response.sid))
        for key, value in pairs(response.statevars) do
          log.info (key .. ' / ' .. value)
        end
        device:set_field("upnp_sid", response.sid)      -- it is driver responsibility to save/manage subscription ids (sid)
        return response
      end
    else
      log.warn ('Failed to subscribe to service: ' .. serviceID)
    end
  else
    log.debug ('Service ID parm missing for subscribing: ' .. upnpdev.uuid)
  end
end
  
-- Periodic subscription renewal routine
local function resubscribe_all()
  
  local device_list = upnpDriver:get_devices()

  for _, device in ipairs(device_list) do
    
    local sid = device:get_field("upnp_sid")
    if sid then
      
      local upnpdev = device:get_field("upnpdevice")
      
      if upnpdev.online then
        upnpdev:unsubscribe(sid)
        device:set_field("upnp_sid", nil)
        local serviceID = device:get_field("upnp_serviceID")
        log.info("Re-subscribing to " .. device.label)
        subscribe_device(device, serviceID, SUBSCRIBETIME)
      else
        log.warn(string.format("%s is offline, can't re-subscribe now", device.label))
      end
    end
  end
end


-- Callback to handle UPnP device status & config changes; invoked by the UPnP library device monitor 
local function status_changed_callback(device)
  
  log.debug ("Device change callback invoked")

  -- 1.Examine upnp device metadata for important changes (online/offline status, bootid, configid, etc)
  
  local upnpdev = device:get_field("upnpdevice")
  local sid = device:get_field("upnp_sid")
  
  if upnpdev.online then
  
    log.info ("Device is back online")
    device:online()
    
    -- 2.Refresh SmartThings capability attributes
    update_ST_capattrs(device)

    -- 3.Refresh any important values from device and service descriptions
    
    -- 4.Send any necessary commands to device
    
    -- 5.Restart subscription for the device
    
    if sid then
      local serviceID = device:get_field("upnp_serviceID")
      subscribe_device (device, serviceID, SUBSCRIBETIME)
    end  
    
  else
    log.info ("Device has gone offline")
    device:emit_event(upnpcap_expiration.expiration(''))
    device:offline()
    if sid then
      upnpdev:cancel_resubscribe(sid)
    end
  end
end


-- Example routine to send a command to the UPnP device
local function send_command(upnpdev, serviceID)
  
  local cmd
  local name = upnpdev:devinfo().friendlyName
  
  if name == 'Watson_TTS' then 
    
    -- Set up the service action name and arguments table  
    cmd = { action = 'PlayMessage',
            arguments = {
              ['MessageText'] = 'U-P-N-P device has started',
              ['SpeakingVoice'] = 'en-US_MichaelV3Voice',
              ['AudioOutput'] = 'local',
              ['Volume'] = -2000,
            }
          }
                
  elseif name == 'WAN Connection Device' then
  
    cmd = { action = 'GetConnectionTypeInfo',
            arguments = { }
          }
  
  elseif name == 'WANDevice' then
  
    cmd = { action = 'GetTotalPacketsReceived',
            arguments = { }
          }
  
  else
    return
  end
  
  log.debug (string.format('Sending command "%s" to %s', cmd.action, name))
  
  status, response = upnpdev:command(serviceID, cmd)
    
  if status == 'OK' then
    log.info ('Command success for ' .. serviceID)
    log.info ('Command response table:')
    for key, data in pairs(response) do               -- response contains returned state values from UPnP device
      log.info ('\tAction: ', key)
      log.info ('\tArguments:')
    
      for key2, value2 in pairs(data) do
        log.info ('\t\tName/Value: ', key2, value2)
        if type(value2) == 'table' then
          for key3, value3 in pairs(value2) do
            log.info ('\t\t\t', key3, value3)
          end
        end
      end
    end

  elseif status == 'Error' then
    log.error ('Device could not execute command:')   
    for key, data in pairs(response) do                 -- response contains returned error information from UPnP device
      log.info (key, data)
    end

  elseif status == nil then
    log.error ('Command failed for Service ID ' .. serviceID .. ' / command = ' .. cmd.action)
  end

end
  
  
-- Fetch the service description table for a given Service ID
local function get_service_info(device, serviceID)

  local upnpdev = device:get_field("upnpdevice")
  
  if serviceID then

    log.debug (string.format('Requesting service description %s from %s', serviceID, device.label))
    
    local servicetable = upnpdev:getservicedescription(serviceID)
      
    if servicetable then
    
      -- display a sampling of the service info content
    
      log.info (string.format('Available device control actions for %s (%s):', serviceID, device.label))
      for index, data in ipairs(servicetable.actions) do
        log.info ('\t' .. data.name)
      end
      
      return servicetable
      
    else
      log.error ('Failed to get service description for ' .. serviceID)
    end
  else
    log.debug ('Service ID is missing from get service info request')
  end

end  

-- Show the services and sub-devices available
local function log_device_info(upnpdev)

  local function showservices(services, indent)
  
    if services then
      if #services > 0 then
        log.info (indent .. 'Services:')
        for _, service in ipairs(services) do
          local servname = string.match(service.serviceType, ':service:([%w]+):')
          log.info (string.format('%s\t%s (id=%s)', indent, servname, service.serviceId))
        end
      end 
    end
  end

  local function showdevices(subdevices, indent)
  
    if subdevices then
      if #subdevices > 0 then
        log.info (indent .. 'Subdevices:')
        
        for _, subdev in ipairs(subdevices) do
          log.info (string.format(indent .. '\t⯈ %s', subdev.friendlyName))
          
          if #subdev.services > 0 then
            showservices(subdev.services, indent .. '\t\t')
          end
          
          showdevices(subdev.subdevices, indent .. '\t\t')
          
        end
      end
    end
  end

  -- If root device, show all services/subdevices in the device description

  if upnpdev.usn:find('upnp:rootdevice', nil, 'plaintext') then
  
    -- services of the root device
    log.info (string.format('%s has these components:', upnpdev.description.device.friendlyName))
    if #upnpdev.description.device.services > 0 then
      showservices(upnpdev.description.device.services, '\t')
    end
  
    -- subdevices of the root device
  
    if upnpdev.description.device.subdevices then
      if #upnpdev.description.device.subdevices > 0 then
        showdevices(upnpdev.description.device.subdevices, '\t')
      end
    end
  else
  
    -- Show info only for our specific device in case it's a multi-tier device
    
    local thisdevmeta = upnpdev:devinfo()
    
    if #thisdevmeta.services > 0 then
      log.info (string.format('%s has these components:', thisdevmeta.friendlyName))
      showservices(thisdevmeta.services, '\t')
    end
    
    if thisdevmeta.subdevices then
      if #thisdevmeta.subdevices > 0 then
        showdevices(thisdevmeta.subdevices, '\t')
      end
    end
  end
  
end


-- Here is where we perform all our device startup tasks
local function startup_device(device, upnpdev)

  -- MANDATORY: Must be called to establish linkage between Edge device and UPnP device objects
  upnpdev:init(upnpDriver, device)             -- creates 'upnpdevice' field in device object (among other things) 

  -- INITIALIZE UPNP DEVICE ONLINE/OFFLINE MONITORING
  upnpdev:monitor(status_changed_callback)     -- invoke given callback whenever UPnP device online status changes
  
  -- SET INITIAL SMARTTHINGS DEVICE STATE & ATTRIBUTES (before subscribing or issuing device commands, which will update it)
  device:online()
  device:emit_event(capabilities.switch.switch('off'))
  
  update_ST_capattrs(device)
  
  -- Do other device startup stuff here
  -- . . .
  log_device_info(upnpdev)
  
  -- GET THE FIRST AVAILABLE DEVICE SERVICE FOR OUR UUID THAT WE'LL USE FOR SUBSCRIPTIONS AND COMMANDS
  ---[[
  local serviceID
  
  local thisdevmeta = upnpdev:devinfo()
  
  if thisdevmeta.services then
  
    if thisdevmeta.services[1] then
  
      serviceID = thisdevmeta.services[1].serviceId                     -- we'll use the first service's serviceId
      device:set_field('upnp_serviceID', serviceID)                     -- we'll want to refer to this elsewhere, so store it
  
      -- RETRIEVE AND INSPECT THE SERVICE DESCRIPTION INFO (optional)
      local service_description = get_service_info(device, serviceID)
      -- >> here is where you would programmatically parse service_description for available commands and state variables

      -- SUBSCRIBE TO THE DESIRED SERVICE
      subscribe_device(device, serviceID, SUBSCRIBETIME)   -- subscription refresh will be called by periodic timer setup in driver mainline
    
    else
      log.warn (string.format('Service not available for device: uuid %s (%s)', upnpdev.uuid, device.label))
    end
    
  else
    log.warn (string.format('No Services available for device: uuid %s (%s)', upnpdev.uuid, device.label))
  end
  
  if serviceID then
    -- SEND A COMMAND TO THE UPnP DEVICE (example)
    send_command(upnpdev, serviceID)
  end
  --]]
end


-- Scheduled re-discover retry routine for unfound devices (stored in unfoundlist table)
-- We'll do a broader search here with 'ssdp:all' in case some badly behaved devices don't respond to specific uuid search target
local function proc_rediscover()

  if next(unfoundlist) ~= nil then
  
    log.debug ('Running periodic re-discovery process for uninitialized devices:')
    for device_network_id, table in pairs(unfoundlist) do
      log.debug (string.format('\t%s (%s)', device_network_id, table.device.label))
    end
  
    upnp.discover('ssdp:all', 3,    
                    function (upnpdev)
      
                      for device_network_id, table in pairs(unfoundlist) do
                        
                        if device_network_id == upnpdev.uuid then
                        
                          local device = table.device
                          local callback = table.callback
                          
                          log.info (string.format('Known device <%s (%s)> re-discovered at %s', device.id, device.label, upnpdev.ip))
                          
                          unfoundlist[device_network_id] = nil
                          callback(device, upnpdev)
                        end
                      end
                    end
    )
  
     -- give discovery some time to finish
    socket.sleep(20)
    -- Reschedule this routine again if still unfound devices
    if next(unfoundlist) ~= nil then
      upnpDriver:call_with_delay(40, proc_rediscover, 're-discover routine')
    end
  end
end


-- Subroutine to do re-discovery (with retries) on a known device
local function dosearch(device, searchtarget)
  
  local waittime = 3
                                            
  log.debug (string.format('Performing re-discovery for <%s (%s)> with search target = %s', device.id, device.label, searchtarget))
  
  local upnpdev
  
  while waittime <= 3 do
    upnp.discover(searchtarget, waittime, function(devobj) upnpdev = devobj end)
    if upnpdev then 
      if device.device_network_id == upnpdev.uuid then; return upnpdev; end
    end
    upnpdev = nil
    waittime = waittime + 1   
    if waittime <= 3 then
      socket.sleep(2)
    end
  end
  
end
  
------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
  log.debug(string.format("INIT handler for: <%s (%s)>", device.id, device.label))

  -- retrieve UPnP device metadata if it exists
  local upnpdev = device:get_field("upnpdevice")
  
  -- if upnp metadata is nil, then this handler was called to re-initialize an existing device (eg after driver reinstall)
  if upnpdev == nil then                    
                                            
    -- Try a targeted discovery for the specific uuid; Search targets must include prefix, e.g. 'uuid:...' or 'urn:....'
    upnpdev = dosearch(device, 'uuid:' .. device.device_network_id) 
  
    if not upnpdev then
      
      log.warn (string.format('<%s (%s)> not responding', device.id, device.label))
      
      -- Save unfound devices in unfoundlist table and schedule a retry routine for later
      if next(unfoundlist) == nil then
        unfoundlist[device.device_network_id] = { ['device'] = device, ['callback'] = startup_device }
        log.warn ('\tScheduling re-discover routine for later')
        upnpDriver:call_with_delay(30, proc_rediscover, 're-discover routine')
      else
        unfoundlist[device.device_network_id] = { ['device'] = device, ['callback'] = startup_device }
      end
    end  
    
    if upnpdev then
      log.info (string.format('Known device <%s (%s)> found at %s', device.id, device.label, upnpdev.ip))
      startup_device(device, upnpdev)
    end
    
  else
      log.debug (string.format('INIT handler: metadata already known for upnp uuid %s (%s)', device.device_network_id, device.label))
  end
end


-- Called when device is initially discovered and created in SmartThings
local function device_added (driver, device)

  local id = device.device_network_id

  log.info(string.format('ADDED handler: <%s (%s)> successfully added; device_network_id = %s', device.id, device.label, id))
  
  -- get UPnP metadata that was squirreled away when device was created
  upnpdev = newly_added[id]
  
  if upnpdev ~= nil then
    startup_device(device, upnpdev)
    
    newly_added[id] = nil                                               -- we're done with it
  
  else
    log.error ('UPnP meta data not found for new device')               -- this should never happen!
  end

  log.debug ('ADDED handler exiting for ' .. device.label)

end

-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  -- Nothing to do here!

end


-- Called when device was deleted via mobile app
local function device_removed(_, device)
  
  log.info("<" .. device.id .. "> removed")
  
  local upnpdev = device:get_field("upnpdevice")
  
  if upnpdev ~= nil then
  
    local sid = device:get_field("upnp_sid")
    if sid ~= nil then
      upnpdev:unsubscribe(sid)
      upnpdev:cancel_resubscribe(sid)
      device:set_field("upnp_sid", nil)
    end  
    
    upnpdev:forget()                                                    -- stop monitoring & allow for later re-discovery 
    
  else
    log.error ('No UPnP data found for deleted device')                 -- this should never happen!
  end
    
end

-- This lifecycle handler is currently being invoked prior to updating the driver; not sure what to do here...
local function handler_infochanged(driver, device, event, args)

  log.debug ('INFOCHANGED handler; event=', event)
  
  device:offline()
  local upnpdev = device:get_field("upnpdevice")
  
  if upnpdev ~= nil then
    
    local sid = device:get_field("upnp_sid")
    if sid ~= nil then
      log.info ('Unsubscribing from device: ', device.label)
      upnpdev:unsubscribe(sid)
      upnpdev:cancel_resubscribe(sid)
      device:set_field("upnp_sid", nil)
    end  
    
  end
  
  --[[
  log.debug ('Old device info:')
  for key, value in pairs(args) do
    log.debug (key, value)
    if type(value) == 'table' then
      for k2, val2 in pairs(value) do
        log.debug ('\t' .. k2, val2)
        if type(val2) == 'table' then
          for k3, val3 in pairs(val2) do
            log.debug ('\t\t' .. k3, val3)
            if type(val3) == 'table' then
              for k4, val4 in pairs(val3) do
                log.debug ('\t\t\t' .. k4, val4)
              end
            end
          end
        end
      end
    end
  end
  --]]
  
end


-- If the hub's IP address changes, this handler is called
local function lan_info_changed_handler(driver, hub_ipv4)
  if driver.listen_ip == nil or hub_ipv4 ~= driver.listen_ip then
    log.info("Hub IP address has changed, restarting eventing server and resubscribing")
    
    upnp.reset(driver)                                                  -- reset device monitor and subscription event server
    resubscribe_all(driver)
  end
end


-- Perform SSDP discovery to find target device(s) on the LAN
local function discovery_handler(driver, _, should_continue)
  log.debug("Starting discovery")
  
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
                        log.info("\tupnp uuid  = device_network_id = " .. id)

                        newly_added[id] = upnpdev         -- squirrel away UPnP device metadata for device_added handler
                                                          -- ... because there's currently no way to attach it to the new device here :-(
                        assert (
                          driver:try_create_device(create_device_msg),
                          "failed to create device record"
                        )

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
upnpDriver = Driver("upnpDriver", {
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
      [capabilities.switch.commands.on.NAME] = command_handlers.handle_switch_on,
      [capabilities.switch.commands.off.NAME] = command_handlers.handle_switch_off,
    },
   
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = command_handlers.handle_refresh,
    }
   
  }
})

log.debug("**** Driver Script Start ****")

-- Initialize scheduler to periodically run subscription renewal routine
upnpDriver:call_on_schedule(SUBSCRIBETIME-5, resubscribe_all , "Re-subscribe timer")
log.info("Subscription renewal routine scheduled")

upnpDriver:run()
