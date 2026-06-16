#include <stdint.h>
extern uint32_t ipctrace_run(void);
int main(void){return ipctrace_run()==1?0:1;}
