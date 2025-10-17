all: clean
	hugo server

clean:
	-rm -rf public
	-rm -rf themes/hugo-blog-awesome/.git
	-rm -rf themes/hugo-blog-awesome/.github
	-rm -rf themes/hugo-blog-awesome/exampleSite
	-rm -rf themes/hugo-blog-awesome/.devcontainer
