1. Receiver side not recording consumed data/specific stun server
2. Call Quality (Sometime echoing, what else could be done, What if multiple person call to a person same time)? Or only maintain status. So that third person can not call.
3. Deploy a self VPS at web and at my own machine
4. Deploy a web version
5. Smooth the audio, right now sharp or remove noise.
6. AI to summarize the call, alert when something unusual ongoing
7. At samsung galaxy A54, notification is cancellable
8. Start with Boot in setting page
9. Alarm or auto notif. This is different level - may be done via the callee side easily
10. Seek notif permission
11. Upon call turn on, even on lock screen
12. Wire Firebase/also any service as well layer so that can be easily interfaced with other technology
13. Consider using get_storage library

TO PRODUCTION
1. Analytics (measure call length, frequency + number of contacts, direct/turn/stunWit)
2. OnBoarding
3. Google login (to have verified identity)
4. remote config to cap time limit
5. Max per call limit (30 minutes) - remote config, For unsigned user, limit will be max 5minutes so
that they will feel interested to register
6. Max total limit per month 10 hours - remote config
7. 