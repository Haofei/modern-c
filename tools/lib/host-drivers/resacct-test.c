#include <stdint.h>
extern uint32_t resacct_run(void);
int main(void){return resacct_run()==1?0:1;}
