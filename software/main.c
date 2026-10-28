/* Vitis standalone example: send one complete packet, receive ten INT32 logits.
 * Connect the NPU/DMA design described in README.md. This program is not a
 * Linux driver; it must be built against the BSP generated from this XSA. */
#include <string.h>
#include "xparameters.h"
#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "frame_0.h"

#define RX_BYTES 40U
#define POLL_LIMIT 100000000U

static unsigned char tx_buf[MNIST_FRAME_BYTES] __attribute__((aligned(64)));
/* 64 bytes ensure cache invalidation does not touch unrelated data. */
static int rx_buf[16] __attribute__((aligned(64)));
static XAxiDma dma;

int main(void)
{
    XAxiDma_Config *cfg;
    unsigned int count;
    int i, best = 0, status;
    static const int expected[10] = {
        -3830, -10155, -611, -949, -14865,
        -6550, -23745, 12564, -4440, -1124
    };

    /* New SDT BSPs use an IP base address; older BSPs use a device ID. */
#ifdef SDT
    cfg = XAxiDma_LookupConfig(XPAR_XAXIDMA_0_BASEADDR);
#else
    cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
#endif
    if (cfg == NULL || XAxiDma_CfgInitialize(&dma, cfg) != XST_SUCCESS ||
        XAxiDma_HasSg(&dma)) {
        xil_printf("DMA configuration failed or SG is enabled\r\n");
        return XST_FAILURE;
    }

    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    memcpy(tx_buf, mnist_frame_0, MNIST_FRAME_BYTES);
    memset(rx_buf, 0, sizeof(rx_buf));
    Xil_DCacheFlushRange((UINTPTR)tx_buf, sizeof(tx_buf));
    Xil_DCacheFlushRange((UINTPTR)rx_buf, sizeof(rx_buf));

    /* Arm receive before transmit so that the result cannot be missed. */
    status = XAxiDma_SimpleTransfer(&dma, (UINTPTR)rx_buf, RX_BYTES,
                                   XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) return XST_FAILURE;
    status = XAxiDma_SimpleTransfer(&dma, (UINTPTR)tx_buf, MNIST_FRAME_BYTES,
                                   XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) return XST_FAILURE;

    for (count = 0; count < POLL_LIMIT; ++count) {
        if (!XAxiDma_Busy(&dma, XAXIDMA_DMA_TO_DEVICE) &&
            !XAxiDma_Busy(&dma, XAXIDMA_DEVICE_TO_DMA)) break;
    }
    if (count == POLL_LIMIT) {
        xil_printf("DMA timed out; inspect status registers and frame_error\r\n");
        return XST_FAILURE;
    }
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf, sizeof(rx_buf));
    for (i = 0; i < 10; ++i) {
        xil_printf("logit[%d] = %d\r\n", i, rx_buf[i]);
        if (rx_buf[i] != expected[i]) {
            xil_printf("FAIL: logit mismatch\r\n");
            return XST_FAILURE;
        }
        if (rx_buf[i] > rx_buf[best]) best = i;
    }
    xil_printf("PASS: prediction = %d\r\n", best);
    return XST_SUCCESS;
}
