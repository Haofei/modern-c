#include <stdint.h>
extern uint32_t replay_run(void);
int main(void){return replay_run()==1?0:1;}
