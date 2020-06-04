/*
 * Copyright © 2020 Inria.  All rights reserved.
 * See COPYING in top-level directory.
 */

#ifndef HWLOC_PORT_L0_ZET_API_H
#define HWLOC_PORT_L0_ZET_API_H

#include "ze_api.h"

typedef void * zet_sysman_handle_t;

typedef struct {
  char *vendorName;
  char *brandName;
  char *modelName;
  char *serialNumber;
  char *boardNumber;
} zet_sysman_properties_t;

typedef struct {
  struct {
    unsigned domain, bus, device, function;
  } address;
  struct {
    unsigned gen;
    unsigned lanes;
    unsigned maxBandwidth;
  } maxSpeed;
} zet_pci_properties_t;

#define ZET_SYSMAN_VERSION_CURRENT 0

extern ze_result_t zetInit(int);
extern ze_result_t zetSysmanGet(ze_device_handle_t, int, zet_sysman_handle_t *);
extern ze_result_t zetSysmanDeviceGetProperties(zet_sysman_handle_t, zet_sysman_properties_t *);
extern ze_result_t zetSysmanPciGetProperties(zet_sysman_handle_t, zet_pci_properties_t *);

#endif /* HWLOC_PORT_L0_ZET_API_H */
