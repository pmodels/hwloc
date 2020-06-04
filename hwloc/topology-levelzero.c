/*
 * Copyright © 2020 Inria.  All rights reserved.
 * See COPYING in top-level directory.
 */

#include "private/autogen/config.h"
#include "hwloc.h"
#include "hwloc/plugins.h"

/* private headers allowed for convenience because this plugin is built within hwloc */
#include "private/misc.h"
#include "private/debug.h"

#include <ze_api.h>
#include <zet_api.h>

static int
hwloc_levelzero_discover(struct hwloc_backend *backend, struct hwloc_disc_status *dstatus)
{
  /*
   * This backend uses the underlying OS.
   * However we don't enforce topology->is_thissystem so that
   * we may still force use this backend when debugging with !thissystem.
   */

  struct hwloc_topology *topology = backend->topology;
  enum hwloc_type_filter_e filter;
  ze_result_t res;
  ze_driver_handle_t *drh;
  uint32_t nbdrivers, i, k;

  assert(dstatus->phase == HWLOC_DISC_PHASE_IO);

  hwloc_topology_get_type_filter(topology, HWLOC_OBJ_OS_DEVICE, &filter);
  if (filter == HWLOC_TYPE_FILTER_KEEP_NONE)
    return 0;

  res = zeInit(0);
  if (res != ZE_RESULT_SUCCESS) {
    if (!hwloc_hide_errors()) {
      fprintf(stderr, "Failed to initialize LevelZero in ze_init(): %d\n", (int)res);
    }
    return 0;
  }

  res = zetInit(0);
  if (res != ZE_RESULT_SUCCESS) {
    if (!hwloc_hide_errors()) {
      fprintf(stderr, "Failed to initialize LevelZero tools in zet_init(): %d\n", (int)res);
    }
    return 0;
  }

  nbdrivers = 0;
  res = zeDriverGet(&nbdrivers, NULL);
  if (res != ZE_RESULT_SUCCESS || !nbdrivers)
    return 0;
  drh = malloc(nbdrivers * sizeof(*drh));
  if (!drh)
    return 0;
  res = zeDriverGet(&nbdrivers, drh);
  if (res != ZE_RESULT_SUCCESS) {
    free(drh);
    return 0;
  }

  k = 0;
  for(i=0; i<nbdrivers; i++) {
    uint32_t nbdevices, j;
    ze_device_handle_t *dvh;
    char buffer[13];

    nbdevices = 0;
    res = zeDeviceGet(drh[i], &nbdevices, NULL);
    if (res != ZE_RESULT_SUCCESS || !nbdevices)
      continue;
    dvh = malloc(nbdevices * sizeof(*dvh));
    if (!dvh)
      continue;
    res = zeDeviceGet(drh[i], &nbdevices, dvh);
    if (res != ZE_RESULT_SUCCESS) {
      free(dvh);
      continue;
    }

    for(j=0; j<nbdevices; j++) {
      hwloc_obj_t osdev, parent;
      zet_sysman_handle_t tdvh;

      osdev = hwloc_alloc_setup_object(topology, HWLOC_OBJ_OS_DEVICE, HWLOC_UNKNOWN_INDEX);
      snprintf(buffer, sizeof(buffer), "ze%u", k); // ze0d0 ?
      osdev->name = strdup(buffer);
      osdev->depth = HWLOC_TYPE_DEPTH_UNKNOWN;
      osdev->attr->osdev.type = HWLOC_OBJ_OSDEV_COPROC;

      hwloc_obj_add_info(osdev, "Backend", "LevelZero");

      parent = NULL;

      res = zetSysmanGet(dvh[j], ZET_SYSMAN_VERSION_CURRENT, &tdvh);
      if (res == ZE_RESULT_SUCCESS) {
        zet_pci_properties_t pci;
        zet_sysman_properties_t prop;

        res = zetSysmanDeviceGetProperties(tdvh, &prop);
        if (res == ZE_RESULT_SUCCESS) {
          /* these strings aren't useful as of levelzero 0.91 implementation:
           * prop.Vendor is "Unknown" or "Intel(R) Corporation"
           * prop.Model is "0x1234" model id
           * prop.serialNumber is "Unknown"
           * prop.bradName is "Unknown" (subvendor name)
           * prop.boardNumber is "Unknown"
           */
#if 0
          if (strcmp((const char *) prop.vendorName, "Unknown"))
            hwloc_obj_add_info(osdev, "Vendor", (const char *) prop.vendorName);
          if (strcmp((const char *) prop.modelName, "Unknown"))
            hwloc_obj_add_info(osdev, "Model", (const char *) prop.modelName);
          if (strcmp((const char *) prop.brandName, "Unknown"))
            hwloc_obj_add_info(osdev, "Subvendor", (const char *) prop.brandName);
          if (strcmp((const char *) prop.serialNumber, "Unknown"))
            hwloc_obj_add_info(osdev, "SerialNumber", (const char *) prop.serialNumber);
          if (strcmp((const char *) prop.boardNumber, "Unknown"))
            hwloc_obj_add_info(osdev, "BoardNumber", (const char *) prop.boardNumber);
#endif
        }

        res = zetSysmanPciGetProperties(tdvh, &pci);
        if (res == ZE_RESULT_SUCCESS) {
          parent = hwloc_pci_find_parent_by_busid(topology,
                                                  pci.address.domain,
                                                  pci.address.bus,
                                                  pci.address.device,
                                                  pci.address.function);
          if (parent && parent->type == HWLOC_OBJ_PCI_DEVICE) {
            if (pci.maxSpeed.maxBandwidth)
              parent->attr->pcidev.linkspeed = ((float)pci.maxSpeed.maxBandwidth)/1000/1000/1000;
          }
        }
      }
      if (!parent)
        parent = hwloc_get_root_obj(topology);

      hwloc_insert_object_by_parent(topology, parent, osdev);
      k++;
    }

    free(dvh);
  }

  free(drh);
  return 0;
}

static struct hwloc_backend *
hwloc_levelzero_component_instantiate(struct hwloc_topology *topology,
                                      struct hwloc_disc_component *component,
                                      unsigned excluded_phases __hwloc_attribute_unused,
                                      const void *_data1 __hwloc_attribute_unused,
                                      const void *_data2 __hwloc_attribute_unused,
                                      const void *_data3 __hwloc_attribute_unused)
{
  struct hwloc_backend *backend;

  backend = hwloc_backend_alloc(topology, component);
  if (!backend)
    return NULL;
  backend->discover = hwloc_levelzero_discover;
  return backend;
}

static struct hwloc_disc_component hwloc_levelzero_disc_component = {
  "levelzero",
  HWLOC_DISC_PHASE_IO,
  HWLOC_DISC_PHASE_GLOBAL,
  hwloc_levelzero_component_instantiate,
  10, /* after pci */
  1,
  NULL
};

static int
hwloc_levelzero_component_init(unsigned long flags)
{
  if (flags)
    return -1;
  if (hwloc_plugin_check_namespace("levelzero", "hwloc_backend_alloc") < 0)
    return -1;
  return 0;
}

#ifdef HWLOC_INSIDE_PLUGIN
HWLOC_DECLSPEC extern const struct hwloc_component hwloc_levelzero_component;
#endif

const struct hwloc_component hwloc_levelzero_component = {
  HWLOC_COMPONENT_ABI,
  hwloc_levelzero_component_init, NULL,
  HWLOC_COMPONENT_TYPE_DISC,
  0,
  &hwloc_levelzero_disc_component
};
