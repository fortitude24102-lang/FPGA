#include "platform.h"

#include "xil_cache.h"

void init_platform(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();
}

void cleanup_platform(void)
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();
}
