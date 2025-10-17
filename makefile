all: clean
	hugo

server:
	hugo server

clean:
	-rm -rf docs
	-rm -rf resources
	-rm -rf themes/hugo-blog-awesome/.git
	-rm -rf themes/hugo-blog-awesome/.github
	-rm -rf themes/hugo-blog-awesome/exampleSite
	-rm -rf themes/hugo-blog-awesome/.devcontainer
