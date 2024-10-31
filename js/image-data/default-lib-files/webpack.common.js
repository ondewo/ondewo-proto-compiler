const path = require('path');
const webpack = require('webpack');

/*
 * SplitChunksPlugin is enabled by default and replaced
 * deprecated CommonsChunkPlugin. It automatically identifies modules which
 * should be splitted of chunk by heuristics using module duplication count and
 * module category (i. e. node_modules). And splits the chunks…
 *
 * It is safe to remove "splitChunks" from the generated configuration
 * and was added as an educational example.
 *
 * https://webpack.js.org/plugins/split-chunks-plugin/
 *
 */

/*
 * We've enabled TerserPlugin for you! This minifies your app
 * in order to load faster and run less javascript.
 *
 * https://github.com/webpack-contrib/terser-webpack-plugin
 *
 *
 * https://webpack.js.org/guides/author-libraries/
 */

const TerserPlugin = require('terser-webpack-plugin');

const name = 'ondewo_javascript_lib';

// entryPoint not needed since passed as parameter for webpack in "compile-stubs-2-lib.sh"
// const entryPoint = './public-api.js';

module.exports = {
	mode: 'development',
	// entry: entryPoint,
	plugins: [new webpack.ProgressPlugin()],

	output: {
		path: path.resolve(__dirname, 'lib'),
		filename: name + '.js',
		libraryTarget: 'var'
	},

	module: {
		rules: []
	},

	optimization: {
		minimize: true,
		minimizer: [new TerserPlugin()],

		splitChunks: {
			cacheGroups: {
				vendors: {
					priority: -10,
					test: /[\\/]node_modules[\\/]/
				}
			},

			chunks: 'async',
			minChunks: 1,
			minSize: 30000,
			name: false
		}
	}
};
