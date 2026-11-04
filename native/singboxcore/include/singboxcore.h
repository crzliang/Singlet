#ifndef SINGLET_SINGBOXCORE_H
#define SINGLET_SINGBOXCORE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Caller must free strings returned by SingletVersion / SingletLastError /
 * SingletClashAPIBaseURL / SingletStatusJSON / SingletMemoryJSON via SingletFreeString. */

const char* SingletVersion(void);
const char* SingletLastError(void);
void SingletFreeString(char* p);

/* 0 = success; non-zero = failure (see SingletLastError). */
int SingletStart(const char* config_path, const char* clash_api_base_url);
int SingletStop(void);
int SingletIsRunning(void);

const char* SingletClashAPIBaseURL(void);
const char* SingletStatusJSON(void);
const char* SingletMemoryJSON(void);

#ifdef __cplusplus
}
#endif

#endif /* SINGLET_SINGBOXCORE_H */
