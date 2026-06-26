.PHONY: test

test:
	chmod +x ./video_normalize.sh
	chmod +x ./tests/smoke.sh
	./tests/smoke.sh
